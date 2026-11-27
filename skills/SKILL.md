---
name: hsbctl
description: Create, inspect, modify and delete Tyk test deployments ("helm sandboxes", namespaces hsandbox-N) on the local k3s/minikube cluster with the hsbctl script from ~/code/helm-sandbox. Use whenever asked to spin up / reproduce on / tear down a Tyk stack, control plane or data plane at a given Tyk version, to get a sandbox's dashboard/gateway/Grafana URL, admin key, org id, Redis/Mongo/Postgres connection, to tail logs or shell into a sandbox pod, to change a deployment's image version or replica count, to publish test APIs, or to install Tyk Operator or Prometheus/Grafana monitoring into the cluster.
---

# hsbctl — Tyk helm sandbox control

`hsbctl` (ksh script, on PATH, source at `~/code/helm-sandbox/hsbctl`) deploys Tyk with the
official Tyk helm charts into a namespace per sandbox (`hsandbox-1`, `hsandbox-2`, …). Each
sandbox is self-contained: its own Redis, Mongo or Postgres (bitnami charts), a `bastion` debug
pod that also serves plugin bundles, and an `httpbin` pod for local upstream traffic.

It is a personal test tool, not a product. When behaviour is unclear, read the script —
the `case $1 in` dispatcher near the end (`create)`, `get)`, `info)`, …) is the source of truth.
The `help` text and README cover all subcommands and create options, but not the gotchas below
(see "Gotchas" and "Undocumented bits").

## Environment facts

- Config: `~/.tyk-sandbox` is sourced on every run. It holds `K8S_DEPLOYMENT` (`k3s` or
  `minikube`; check with `grep ^K8S_DEPLOYMENT ~/.tyk-sandbox`), licences (`SBX_LICENSE`, `SBX_MDCB_LICENSE`), `SBX_USER` and `SBX_PASSWORD`
  (base64) for the dashboard admin, `SBX_HOST_IP_ADDR`. **It contains licences — never print
  or cat it**; grep for a single non-secret key if needed.
- k3s: `KUBECONFIG=~/.kube/k3s-config`, and plain `kubectl`/`helm` work directly. minikube:
  `KUBECONFIG=~/.kube/minikube-config`, and hsbctl aliases kubectl to
  `minikube kubectl -- --cluster=$CLUSTER`. `hsbctl init` adds the export to `~/.bashrc`.
- Services are NodePorts on the host IP (`ip route get 1.1.1.1` src). URLs look like
  `http://<host-ip>:<nodeport>/`.
- Plugin bundles: `~/.tyk/plugins/<gw-column>/` is served by the bastion at
  `http://bastion:8000/<gw-column>/`, where `<gw-column>` is the **raw gateway column** of the
  versions row, including the `-1` suffix (e.g. `~/.tyk/plugins/5.13.6-1/`, not `5.13.6`). Gateways
  already have `TYK_GW_BUNDLEBASEURL` pointing there and the bundle downloader + JSVM enabled.
  Drop a bundle zip in that dir and reference it by name in the API definition.
- The bastion image (`saintpeter/bastion-9:latest`) is built locally and cannot be pulled from a
  registry. If the bastion pod is stuck in `ErrImagePull`/`ImagePullBackOff`, rebuild it with
  `~/code/helm-sandbox/tbi/k3s-build-bastion.sh` (it uses sudo).
- Dependencies: ksh, kubectl, helm, jq, yq, envsubst, redis-cli (needed by `create` to read the
  admin key), optionally mongosh/psql.

## Namespace arguments

Anywhere a sandbox is expected you can pass `3` or `hsandbox-3`; a namespace created with
`-N name` is referred to by that name. `info` and `version` with no argument cover all sandboxes
(namespaces labelled `creator=hsbctl`).

## Commands

### create
```
hsbctl create -v <version> -t "<description>" [options]
```
`-v` is a refNo (first column) from `~/code/helm-sandbox/tyk-versions.list`, e.g. `5.8.20`.
That row fixes gateway, dashboard, pump, MDCB and portal versions. For EE or FIPS use the plain
row plus a flag (`-v 5.13.0 -e`, `-v 5.13.0 -f`). Do **not** use the `_ee` / `_fips` rows:
hsbctl ignores the `ee-` marker, so `5.13.0_ee` gives a normal non-EE gateway, and `5.13.0_fips`
produces image tags like `vfips-5.13.0` that don't exist.
If the version is missing from the file, create fails — add a row (format is documented at the
top of the file; refNo must not contain `-`). Check with
`grep '^<ver>,' ~/code/helm-sandbox/tyk-versions.list`.

Always give `-t` a meaningful description (ticket number + purpose) — it is what identifies the
sandbox later in `info`.

| Option | Meaning |
|---|---|
| `-C tyk-stack\|tyk-control-plane\|tyk-data-plane` | chart (default `tyk-stack`) |
| `-p` | Postgres instead of Mongo (version ≥ 4) |
| `-P` | also deploy Enterprise Developer Portal (implies `-p`), with the sandbox dashboard registered as its `tyk-pro` provider |
| `-e` / `-f` | EE gateway image / FIPS images for all components (mutually exclusive) |
| `-g N` | gateway replicas |
| `-h` | HTTPS on gateways |
| `-G` | deploy a gRPC plugin server pod and point the gateway coprocess at it |
| `-E file` | `VAR=value` lines added as extraEnvs to every component (dashboard, gateway, pump, portal, MDCB) |
| `-d debug\|info\|warn\|error` | TYK_LOGLEVEL for all components (default debug; `warn` becomes `warning`) |
| `-H <chart-ver>` | pin tyk helm chart version (default latest) |
| `-V values.yaml` | use a values file instead; overrides all other Tyk options (`-H` is ignored too). `-v` is still required, and Redis/Mongo/PG are still deployed |
| `-N name` | explicit namespace name instead of next free `hsandbox-N` |
| `-n` | don't publish the sample APIs (`APIs/*.yaml`) |
| `-o` | create an OperatorContext (needs `hsbctl setup operator` first); publishes `APIs/CRDs/*.yaml` instead |
| `-D N` / `-r N` | Mongo/PG PVC size Gi (default 5) / Redis PVC size Gi (default 1) |
| `-s` | MDCB synchroniser (control plane: MDCB sync worker; data plane: gateway). Warns and is ignored on tyk-stack |
| `-T tag1,tag2` | gateway sharding segment tags (data plane only) |
| `-R <cp-sandbox>` | data plane attached to an existing tyk-control-plane sandbox (implies `-C tyk-data-plane`) |
| `-M host:port -K <api key> -O <orgid> [-S]` | data plane attached to an external MDCB (all three required; `-S` = SSL) |

Common recipes:
```
hsbctl create -v 5.8.20 -t "TT-12345 repro"                       # stack, mongo
hsbctl create -v 5.8.20 -p -t "TT-12345 PG"                        # stack, postgres
hsbctl create -v 5.8.20 -C tyk-control-plane -t "CP for TT-12345"  # -> e.g. hsandbox-2
hsbctl create -v 5.8.20 -R 2 -g 2 -T edge1 -t "DP for TT-12345"    # data plane on hsandbox-2
```
#### Gotchas
- `-E` file: `VAR=value` per line, split on the first `=` (values may contain `=`). Blank lines,
  `#` comments and a leading `export ` are fine. **Values must not contain spaces or commas**
  (they go unquoted into `helm --set-string`); for those, edit the deployment afterwards or use `-V`.
- A data plane gets a unique MDCB group ID per namespace. Its gateway and pump extraEnvs come
  from `-E`; dashboard envs are dropped.

Create takes several minutes (waits for DBs, then helm install with bootstrap jobs). Run it in
the background and wait for it rather than with a short timeout. At the end it prints versions,
pods and the same report as `info`. The dashboard admin is `$SBX_USER` (or `user@admin.com` /
`ABC-123` when unset).

### info / version
```
hsbctl info [ns...]      # versions, pods, URLs, DB/redis connection commands, AdminKey, OrgID
hsbctl info monitoring   # Grafana URL, or a warning if monitoring isn't installed
hsbctl version [ns...]   # image of every deployment
```
`info` with no arguments does not include `monitoring` (that namespace isn't labelled `creator=hsbctl`).
`info` output contains DB/Redis passwords and the admin key — fine to use locally, redact before
pasting anywhere shared.

### get — single values for scripting
```
hsbctl get <ns> chart|description|dashboard|gateway|grafana|key|orgid|mdcb|mongo|portal|portal-token|postgres|redis|redis-password|redis-port|release|values
```
`portal` prints the portal URL and `portal-token` the portal admin's API token for
`/portal-api` calls (`-P` sandboxes; the token is read from the chart's `dev-portal-job-*` log at
create time and kept in `sandbox-details`). `grafana` prints `http://<ip>:<nodeport>/` for the cluster-wide Grafana. Any existing namespace
works as `<ns>`, e.g. `hsbctl get monitoring grafana`. It exits 1 if `setup monitoring` hasn't
been run. `admin` is an alias for `key`.
Examples:
```
KEY=$(hsbctl get 1 key); DASH=$(hsbctl get 1 dashboard); GW=$(hsbctl get 1 gateway)
curl -s -H "Authorization: $KEY" ${DASH}api/apis | jq '.apis[].api_definition.name'
eval "$(hsbctl get 1 redis) --scan --pattern 'apikey-*'"   # redis prints a REDISCLI_AUTH=... redis-cli ... command
hsbctl get 1 values                                         # helm values actually deployed
```
`key`/`orgid`/`mongo`/`postgres` only exist for tyk-stack and tyk-control-plane; `mdcb` only for
tyk-control-plane; on other charts they print `[FATAL]` to stderr and exit 1. For a data plane,
read the key from its control plane (`hsbctl get <cp> key`; `info <dp>` shows `ControlPlane`). The admin key and org id come from the `sandbox-details` ConfigMap in the
namespace (also holds description, chart, versions, DB type, control-plane name).

### publish — load API definitions into a dashboard
```
hsbctl publish <ns> file1.json file2.yaml ...
```
Handles Tyk OAS (JSON or YAML, detects `x-tyk-api-gateway`), plain OAS YAML (import), classic
`api_definition` payloads, and raw dashboard exports. tyk-stack / tyk-control-plane only.

### logs / shell / monitor
```
hsbctl logs <ns> <pod-substring>      # kubectl logs -f of first matching pod (blocks; run in background or use kubectl logs --tail)
hsbctl shell <ns> bastion             # interactive bash with TYK_KEY, TYK_ORG, TYK_DSHB, TYK_GW set
hsbctl monitor <ns> <pod-substring>   # kubectl top every 60s, loops forever
```
`logs`, `shell` and `monitor` are interactive / never exit. As an agent prefer the non-interactive
equivalents: `kubectl logs -n hsandbox-1 deploy/<name> --tail=200`,
`kubectl exec -n hsandbox-1 deploy/bastion -- curl -s ...`. Pod names contain e.g. `gateway`,
`dashboard`, `pump`, `mdcb`, `dev-portal`, `bastion`, `httpbin`, `tyk-redis`, `tyk-mongo`,
`tyk-postgres`. Most Tyk images are distroless — use the bastion for curl etc.

In-cluster URLs: dashboard `http://dashboard-svc-<release>-tyk-dashboard.<ns>.svc:3000`, gateway
`http://gateway-svc-<release>-tyk-gateway.<ns>.svc:8080`, MDCB
`mdcb-svc-<release>-tyk-mdcb.<ns>.svc:9091`.
Local upstream: **`http://httpbin.org`**. The httpbin pod has `hostname: httpbin`,
`subdomain: org`, plus a Service named `org`. Inside the sandbox namespace, `httpbin.org` therefore
resolves to the local pod and not the internet site. The sample APIs use
`http://httpbin.org/anything`, so test traffic stays in the cluster. Release names:
`tykstack`, `tykcontrolplane`, `tykdataplane`.

### modify — change a running deployment
```
hsbctl modify <ns> <deployment-substring> -c <replicas>
hsbctl modify <ns> <deployment-substring> -v <image-tag>   # 'v' prefix added if missing; no validation
```
The deployment substring must match exactly one deployment (`kubectl get deploy -n <ns>`). This
edits the Deployment directly, so a later helm upgrade will revert it. Waits for rollout.

### delete
```
hsbctl delete <ns...>      # also: hsbctl rm <ns...>
```
Removes Tyk CRDs/OperatorContext first if present, deletes the namespace, tidies Released PVs.
**Destructive and irreversible — only delete sandboxes the user named or that you created in this
session; confirm before deleting anything else.** Check `hsbctl info <ns>` description first.
The script itself asks for no confirmation, and it doesn't check for data planes attached to a
control plane. Deleting a CP leaves its DPs pointing at a dead MDCB, so delete them together.

### cluster-level
```
hsbctl init                 # one-off: install k3s/minikube, cert-manager, helm repos, bastion image; edits ~/.bashrc
hsbctl start                # minikube only: start the cluster
hsbctl setup operator       # install Tyk Operator (HSBX_OPERATOR_VERSION to pin)
hsbctl setup monitoring     # kube-prometheus-stack in ns 'monitoring' + Tyk Grafana dashboards; rerun prints Grafana URL
```
`init` modifies the host (sudo, ~/.bashrc) — don't run it without being asked. `setup monitoring`
honours `HSBX_KPS_VERSION` (default 92.0.0) and `HSBX_TYK_OBSERVABILITY_REF` (default main);
Grafana login is the Tyk dashboard admin. It fetches the Tyk dashboards from GitHub (they land in
Grafana folder `Tyk`), but **they stay empty unless the Tyk components export OpenTelemetry
metrics into Prometheus, and hsbctl doesn't configure that**. Pod CPU and memory work out of the
box: 'Kubernetes / Compute Resources / Namespace (Pods)'. Afterwards, `hsbctl get monitoring
grafana` gives the URL. The repo-root `./setup-monitoring` script is the legacy version (no Tyk
dashboards, no values file); use `hsbctl setup monitoring` instead.

## Undocumented bits (not in `hsbctl` help)
- `rm` is an alias for `delete`.
- A leading `-C <minikube profile>` before the subcommand selects a minikube cluster (minikube only).
- Every create adds gateway envs `TYK_GW_ENABLEBUNDLEDOWNLOADER`, `TYK_GW_ENABLEHASHEDKEYSLISTING`,
  `TYK_GW_ENABLEJSVM`, `TYK_GW_BUNDLEBASEURL`, and dashboard `TYK_DB_SECURITY_CSRFALLOWMISSINGORIGIN`;
  gateway image defaults to non-EE `tykio/tyk-gateway`.
- Other defaults applied silently: gateway access logs on; dashboard audit logs on (stored in the
  DB, detailed recording); pump table sharding on with Postgres, and
  `MONGOAGGREGATE_META_USEMIXEDCOLLECTION=false` with Mongo. With `-P`, the portal gets
  `PORTAL_DISABLE_CSRF_CHECK=true`. A data plane's pump has hybrid aggregate analytics enabled.
- `EXTRA_NAMESPACE_LABELS='k=v ...' hsbctl create ...` adds labels to the namespace. With
  `istio-injection=enabled`, `info` also reports Kiali/Grafana/Tracing from `istio-system`.
- On an EC2 host (detected via DMI board vendor), `info` also prints `localhost` URLs and a
  ready-made `ssh -g -L ...` port-forward command. `EC2/aws-setup` provisions such a host.

## Working pattern
1. `hsbctl info` to see what already exists (don't reuse someone's sandbox for a different purpose).
2. Confirm the version row exists in `tyk-versions.list`.
3. `hsbctl create ...` in the background; wait for completion; on failure inspect
   `kubectl get pods -n <ns>`, `kubectl get jobs -n <ns>` (bootstrap jobs) and their logs.
4. Drive it with `hsbctl get` values + curl / redis-cli / kubectl exec into the bastion.
5. Report the namespace name to the user; delete it only if asked.

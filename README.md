# helm-sandbox

Deploy a complete Tyk installation, at almost any released version, into its own Kubernetes
namespace with one command. Run as many side by side as your machine can hold.

`hsbctl` (helm sandbox control) is the command-line tool. It installs Tyk with the **official
Tyk helm charts** into **sandboxes**: namespaces called `hsandbox-1`, `hsandbox-2`, … on a local
k3s or minikube cluster. Each sandbox gets everything it needs: Redis, MongoDB or PostgreSQL,
the Tyk components, a debug pod and a local upstream service. Afterwards, `hsbctl` reports the
URLs, keys and connection strings you need to use it.

It is built for support and engineering work: reproducing a customer issue on the exact
version and chart they run, comparing behaviour between versions, testing control plane / data
plane (MDCB) setups, and testing plugins or config changes.

> **Note:** this is a personal test tool, not a Tyk product. It has no support or warranty of
> any kind, and the repo could change or disappear at any time. Sandboxes are for test machines.
> Every service is a NodePort on the host's IP, the passwords and secrets are well known, and
> the gateway runs at debug log level. Don't run it on a host reachable from untrusted networks,
> and don't put real customer data in it.

---

## Contents

- [Tyk in five minutes](#tyk-in-five-minutes)
- [What a sandbox contains](#what-a-sandbox-contains)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration: ~/.tyk-sandbox](#configuration-tyk-sandbox)
- [Quick start](#quick-start)
- [Concepts](#concepts)
- [Command reference](#command-reference)
- [Common tasks](#common-tasks)
- [Adding a new Tyk version](#adding-a-new-tyk-version)
- [Running on AWS EC2](#running-on-aws-ec2)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [AI coding agents](#ai-coding-agents)

---

## Tyk in five minutes

This guide assumes you know Kubernetes and helm, but not Tyk. Here is the minimum you need.

### Components

| Component | What it does | Needs |
|---|---|---|
| **Gateway** | The API gateway. It proxies client requests to upstream services and applies auth, rate limits, quotas, transforms and plugins. This is the data path | Redis |
| **Dashboard** | Management UI and REST API. You create APIs, policies and keys here, and it pushes them to the gateways. It also shows analytics. Licensed | Redis, and MongoDB or PostgreSQL |
| **Pump** | Moves analytics records out of Redis (where gateways write them) into MongoDB or PostgreSQL, for the dashboard | Redis, DB |
| **MDCB** (Multi Data Centre Bridge) | Connects remote gateway clusters (data planes) to a central dashboard (control plane). Data plane gateways get API definitions and keys from MDCB instead of from a local dashboard. Licensed separately | Redis, DB |
| **Enterprise Developer Portal** (EDP) | A developer portal where API consumers sign up and get keys. Licensed | PostgreSQL here |
| **Tyk Operator** | Kubernetes operator: manage Tyk APIs and policies as CRDs | A dashboard |

Redis holds the gateway's live state: API keys and sessions, rate-limit counters, and the
analytics buffer. MongoDB or PostgreSQL holds the dashboard's state: APIs, policies, users,
orgs and analytics.

### Deployment models (the three charts)

hsbctl supports these three Tyk helm charts, chosen with `create -C`:

| Chart | What you get | Typical use |
|---|---|---|
| `tyk-stack` (default) | Dashboard, gateway, pump, Redis, DB in one namespace. Gateways load their config from the dashboard | Most reproductions. "Self-managed, single data centre" |
| `tyk-control-plane` | Dashboard, MDCB, gateway, pump, Redis, DB | The central half of a distributed setup |
| `tyk-data-plane` | Gateway(s), pump and Redis only. The gateways connect to a control plane's MDCB | Remote / edge gateways. Pair it with a control plane |

```
 tyk-stack                       tyk-control-plane                tyk-data-plane (one or more)
 ┌──────────────────────┐        ┌──────────────────────┐         ┌──────────────────┐
 │ dashboard ── DB      │        │ dashboard ── DB      │  RPC    │ gateway(s)       │
 │ gateway(s)  pump     │        │ MDCB ◄───────────────┼─────────┤ pump             │
 │ redis                │        │ gateway  pump  redis │  :9091  │ redis            │
 └──────────────────────┘        └──────────────────────┘         └──────────────────┘
```

### Words you'll meet

| Term | Meaning |
|---|---|
| **API definition** | A Tyk API's configuration: listen path, upstream (target) URL, auth, middleware. Comes in two formats: **Tyk OAS** (an OpenAPI document with an `x-tyk-api-gateway` extension; the current format) and **classic** (Tyk's older JSON format) |
| **Listen path** | The path prefix the gateway serves an API on, e.g. `/httpbin/` |
| **Org ID** | Every API, key and policy belongs to an organisation. A sandbox has one org |
| **Admin key** (user API key) | The dashboard admin user's API key. Send it as the `Authorization` header to the dashboard API (`/api/...`) |
| **Gateway secret** | Authenticates calls to the gateway's own API (`/tyk/...`) in the `x-tyk-authorization` header. In sandboxes it is `Secret` |
| **Policy** | A reusable bundle of access rights, rate limits and quotas that keys can be attached to |
| **Plugin bundle** | A zip of custom middleware (JavaScript, Python or Go) that the gateway downloads from a bundle server |
| **Segment tags** (sharding) | Tags on gateways and APIs so that only some gateways load some APIs |

### Licences

The dashboard, MDCB and EDP need licence keys; the gateway and pump don't. hsbctl puts the
licences from `~/.tyk-sandbox` into a Kubernetes secret in each sandbox. See
[Configuration](#configuration-tyk-sandbox). Without a valid dashboard licence, a `tyk-stack` or
`tyk-control-plane` install won't bootstrap.

---

## What a sandbox contains

`hsbctl create` gives you a namespace like this (here a `tyk-stack` sandbox with MongoDB):

| Kind | Name | Notes |
|---|---|---|
| Namespace | `hsandbox-N` | Labelled `creator=hsbctl`. N is the lowest free number |
| ConfigMap | `sandbox-details` | Everything hsbctl remembers about the sandbox: description, chart, versions, DB type, admin key, org ID |
| Helm release | `tyk-redis` | `bitnami/redis`, standalone (no replicas), auth enabled |
| Helm release | `tyk-mongo` or `tyk-postgres` | `bitnami/mongodb` or `bitnami/postgresql` |
| Helm release | `tykstack` / `tykcontrolplane` / `tykdataplane` | The Tyk chart. Its bootstrap jobs create the org, the admin user and the licence |
| Deployment | `bastion` | AlmaLinux debug pod with curl, jq, redis-cli, mongosh, python3. It also serves plugin bundles on port 8000 |
| Deployment + Service | `httpbin` + `org` | A local [httpbin](https://httpbin.org), reachable as `httpbin.org` inside the namespace, so test traffic stays in the cluster |
| Deployment | `grpc-plugin` | Only with `create -G`: a sample gRPC plugin server |
| Secrets | `tyk-system-secrets`, `tyk-admin-account-secrets`, … | Licences, gateway/admin secrets, admin user, DB connection strings |

The bitnami charts use the `bitnamilegacy/*` images. Each Tyk service, and Redis and the DB, is
a **NodePort** service. URLs therefore look like `http://<host-ip>:<nodeport>/`, and `hsbctl info`
tells you which ports. The DB and Redis PVCs use the cluster's default StorageClass
(`local-path` on k3s).

Some settings differ from the chart defaults, chosen to make debugging easier:
- Every Tyk component runs at log level `debug` (change it with `-d`).
- The gateway image is the non-EE `tykio/tyk-gateway`; the charts default to the EE image
  (use `-e` for EE).
- Gateway access logs and dashboard audit logs (stored in the DB) are on.
- The gateway has the bundle downloader, JSVM and hashed key listing enabled.

An idle sandbox uses roughly 100m CPU and 350–400 MiB of memory, plus 1 GiB (Redis) and 5 GiB
(DB) of PVC.

---

## Requirements

- **Linux**, with either **k3s** or **minikube** (docker driver); `hsbctl init` installs
  whichever you choose. k3s is lighter and lets other machines reach the NodePorts directly.
  Other clusters aren't supported; see [Using another cluster](#using-another-cluster).
- `sudo` rights, for `hsbctl init` and for loading the bastion image into k3s.
- **Docker**, to build the bastion image (and as minikube's driver).
- On the host:
  - `ksh`, because hsbctl is a Korn shell script.
  - `kubectl` (on k3s, the one k3s installs is fine) and `helm` (v3 or v4).
  - `jq`; `yq` v4 ([mikefarah/yq](https://github.com/mikefarah/yq)); `envsubst` (package
    `gettext-base` or `gettext`); `curl`; `ip` (iproute2).
  - `redis-cli` (package `redis-tools` or `redis`). **Required**: `create` uses it to read the
    admin key and org ID.
- Optional on the host: `mongosh` and `psql`, to use the connection commands that `info` prints.
- Internet access, to pull charts and images.
- Resources: a few hundred MiB of RAM and about 6 GiB of disk per idle sandbox, more under load.
  If you run many sandboxes you may hit inotify limits; see [Troubleshooting](#troubleshooting).

## Installation

```sh
git clone https://github.com/ps258/helm-sandbox.git ~/code/helm-sandbox
export PATH="$PATH:$HOME/code/helm-sandbox"      # add to ~/.bashrc
```

Create `~/.tyk-sandbox` before going further (see [Configuration](#configuration-tyk-sandbox)).
It sets which kind of cluster `init` builds.

### Set up the cluster: `hsbctl init`

`hsbctl init` is a one-off step. It sets up the cluster chosen by `K8S_DEPLOYMENT` in
`~/.tyk-sandbox`.

**k3s** (`K8S_DEPLOYMENT=k3s`):
- Installs k3s (a pinned version) with Traefik disabled, unless `/usr/local/bin/k3s` already
  exists. It configures larger container log files for the kubelet.
- Copies the kubeconfig to `~/.kube/k3s-config`.
- Installs cert-manager.
- Adds the `tyk-helm` and `bitnami` helm repositories.
- Builds the bastion image and imports it into k3s. The image is pinned so that image garbage
  collection can't remove it.
- Appends `export KUBECONFIG=~/.kube/k3s-config` to `~/.bashrc`.

**minikube** (`K8S_DEPLOYMENT=minikube`, the script's default if the variable is unset):
- Starts a minikube cluster with the docker driver, all CPUs and all the host's memory.
- Mounts `~/.tyk/plugins` into the node.
- Enables the `metrics-server` and `dashboard` addons.
- Installs cert-manager and the helm repositories.
- Builds the bastion image inside minikube.
- Appends a `kubectl` alias and `export KUBECONFIG=~/.kube/minikube-config` to `~/.bashrc`.

Afterwards, **source `~/.bashrc`** (or log in again) so that `KUBECONFIG` is set. Then check:

```sh
kubectl get nodes
hsbctl info          # "No helm sandboxes configured"
```

On minikube, `hsbctl start` starts a stopped cluster. Every hsbctl command also starts it
quietly if it is stopped.

### Using another cluster

`K8S_DEPLOYMENT=none` turns off the k3s/minikube specific steps, and URLs use
`SBX_HOST_IP_ADDR`. This mode is untested. You'd need to make the bastion image available to
the cluster yourself, set up a plugin directory, and make NodePorts reachable. Expect to edit the
script.

## Configuration: `~/.tyk-sandbox`

hsbctl sources `~/.tyk-sandbox` (a shell file) at every run.

```sh
K8S_DEPLOYMENT=k3s                   # k3s or minikube (or none, see above)
SBX_LICENSE=eyJhbGciOi...            # Tyk dashboard licence. Also used for EDP and Tyk Operator
SBX_MDCB_LICENSE=eyJhbGciOi...       # MDCB licence. Needed for -C tyk-control-plane
SBX_USER=me@example.com              # dashboard admin user (also Grafana's admin)
SBX_PASSWORD=Y2hhbmdlbWU=            # that user's password, base64 encoded: echo -n 'changeme' | base64
SBX_HOST_IP_ADDR=192.168.1.20        # only used with K8S_DEPLOYMENT=none
```

| Variable | Effect |
|---|---|
| `K8S_DEPLOYMENT` | Which cluster `init` builds and how hsbctl reaches it. Anything other than `k3s`, `minikube` or `none` is an error |
| `SBX_LICENSE` | Stored in `tyk-system-secrets` as the dashboard, portal and operator licence. Required for `tyk-stack` and `tyk-control-plane` |
| `SBX_MDCB_LICENSE` | Stored as the MDCB licence. Required for `tyk-control-plane` |
| `SBX_USER` + `SBX_PASSWORD` | The dashboard admin user that the chart bootstrap creates. If unset, it's `user@admin.com` / `ABC-123` |

The file holds licences: keep it `chmod 600` and never commit it.

Optional environment variables, set in the file or exported before running hsbctl:

| Variable | Effect |
|---|---|
| `HSBX_OPERATOR_VERSION` | Tyk Operator chart version for `setup operator` (default: latest) |
| `HSBX_KPS_VERSION` | kube-prometheus-stack chart version for `setup monitoring` (default 92.0.0) |
| `HSBX_TYK_OBSERVABILITY_REF` | Git ref of [TykTechnologies/tyk-install](https://github.com/TykTechnologies/tyk-install) to take the Tyk Grafana dashboards from (default `main`) |
| `EXTRA_NAMESPACE_LABELS` | Extra labels for new sandbox namespaces, e.g. `istio-injection=enabled` |

---

## Quick start

```sh
# 1. Which Tyk versions are available? (the first column is what -v takes)
grep -v '^#' ~/code/helm-sandbox/tyk-versions.list | head

# 2. Create a tyk-stack sandbox at 5.16.3. This takes a few minutes: it waits for Redis and
#    MongoDB, then installs the chart and waits for its bootstrap jobs
hsbctl create -v 5.16.3 -t "TT-12345 rate limit repro"
```

At the end, `create` prints a summary (passwords elided here):

```
[INFO]hsandbox-1
HSBX_VERSION=5.16.3 HSBX_CHART=tyk-stack HSBX_DATABASE=mongo HSBX_DB=v5.16.3 HSBX_GW=v5.16.3 HSBX_PMP=v1.18.0
NAME                                               READY   STATUS    RESTARTS   AGE
bastion-f8787fdcc-9nl9q                            1/1     Running   0          3m
dashboard-tykstack-tyk-dashboard-5cb4f94bb7-t2vch  1/1     Running   0          2m
...
hsandbox-1.Description:       TT-12345 rate limit repro
hsandbox-1.Chart:             tyk-stack
hsandbox-1.dashboard:         http://192.168.1.20:32275/
hsandbox-1.gateway:           http://192.168.1.20:32695/
hsandbox-1.mongo:             mongosh --quiet mongodb://root:...@192.168.1.20:31897/tyk_analytics?authSource=admin
hsandbox-1.redis:             REDISCLI_AUTH=... redis-cli -h 192.168.1.20 -p 30896
hsandbox-1.AdminKey:          ...
hsandbox-1.OrgID:             64f0c0ffee00000001a1b2c3
```

```sh
# 3. Use it
GW=$(hsbctl get 1 gateway); DASH=$(hsbctl get 1 dashboard); KEY=$(hsbctl get 1 key)
curl -s ${GW}hello | jq                                  # gateway health check
curl -s ${GW}httpbin/get                                 # sample keyless API, proxied to the local httpbin
curl -s -H "Authorization: $KEY" ${DASH}api/apis | jq '.apis[].api_definition.name'
curl -s -H "x-tyk-authorization: Secret" ${GW}tyk/apis | jq '.[].name'   # the gateway's own API
hsbctl shell 1 bastion                                   # a shell inside the namespace

# 4. Tidy up
hsbctl delete 1
```

Log in to the dashboard URL as `SBX_USER` with the password you base64-encoded.

All the usual tools work too: `kubectl -n hsandbox-1 get all`, `helm list -n hsandbox-1`,
`helm get values tykstack -n hsandbox-1`.

---

## Concepts

### Versions (refNo)

`tyk-versions.list` maps a **refNo** to the version of each component released with it:

```
#refNo,tyk-gateway,tyk-dashboard,tyk-pump,tyk-identity-broker,tyk-sync,tyk-mdcb,tyk-portal
5.16.3,5.16.3-1,5.16.3-1,1.18.0-1,1.8.4-1,2.3.0-1,2.14.0-1,1.20.1-1
```

- `create -v 5.16.3` deploys gateway and dashboard `v5.16.3`, pump `v1.18.0`, and (if the chart
  uses them) MDCB `v2.14.0` and portal `v1.20.1`. The image tag is `v` + the column with the
  trailing `-1` removed. hsbctl doesn't use the TIB and sync columns.
- The file is shared in format with [tyk-sandbox](https://github.com/ps258/tyk-sandbox), and it
  also records which component versions were current at each release.
- `_ee` and `_fips` rows exist in the file but don't work with hsbctl. Use the plain row with
  `-e` or `-f` instead (see [Known limitations](#known-limitations)).
- PostgreSQL (`-p`, `-P`) needs a refNo of 4 or later.

To deploy a version that isn't in the list, add a row: see
[Adding a new Tyk version](#adding-a-new-tyk-version).

### Sandbox names

`create` uses the lowest free `hsandbox-N`, or the name you give with `-N`. Wherever a sandbox
is expected, you can write `3` or `hsandbox-3`. `info` and `version` with no argument cover all
sandboxes (namespaces labelled `creator=hsbctl`).

Always give `create -t` a meaningful description, such as a ticket number and what you're
testing. It's shown by `info` and is the easiest way to remember what each sandbox is for.

### Sandbox state

hsbctl keeps no state outside the cluster. Everything comes from the `sandbox-details`
ConfigMap, the helm releases and the NodePort services. So plain `kubectl` and `helm` commands
are safe to mix in:

```sh
kubectl get cm sandbox-details -n hsandbox-1 -o yaml
```

The exception is `hsbctl modify`, which edits Deployments directly. A later `helm upgrade`
reverts those edits.

### Release and service names

| Chart | Helm release | Dashboard service | Gateway service |
|---|---|---|---|
| tyk-stack | `tykstack` | `dashboard-svc-tykstack-tyk-dashboard:3000` | `gateway-svc-tykstack-tyk-gateway:8080` |
| tyk-control-plane | `tykcontrolplane` | `dashboard-svc-tykcontrolplane-tyk-dashboard:3000` | `gateway-svc-tykcontrolplane-tyk-gateway:8080` |
| tyk-data-plane | `tykdataplane` | (none) | `gateway-svc-tykdataplane-tyk-gateway:8080` |

MDCB, in a control plane, is `mdcb-svc-tykcontrolplane-tyk-mdcb:9091` (RPC), with its health
check on a second port.

### Local upstream: `httpbin.org`

The httpbin pod has hostname `httpbin` and subdomain `org`, and there's a Service called `org`.
Inside the sandbox namespace, `httpbin.org` therefore resolves (through the pod DNS search path)
to the **local** httpbin pod, not the public site. The sample APIs proxy to
`http://httpbin.org/...`, so test traffic never leaves the cluster. You can use it as an upstream
in your own APIs too.

### Plugin bundles

The bastion serves `~/.tyk/plugins` (on the host) at `http://bastion:8000/`. Every gateway is
configured with `TYK_GW_BUNDLEBASEURL=http://bastion:8000/<gw-column>/`. `<gw-column>` is the
raw gateway column of the versions row, e.g. `5.16.3-1`. `create` makes the directory. See
[Load a plugin bundle](#load-a-plugin-bundle).

---

## Command reference

Run `hsbctl` with no arguments for the built-in summary.

### create

```
hsbctl create -v <refNo> -t "<description>" [options]
```

| Option | Meaning |
|---|---|
| `-v <refNo>` | **Required.** Row of `tyk-versions.list` to deploy |
| `-t <text>` | Description, shown by `info`. Always set it |
| `-C <chart>` | `tyk-stack` (default), `tyk-control-plane` or `tyk-data-plane` |
| `-p` | PostgreSQL instead of MongoDB (refNo 4 or later) |
| `-P` | Also deploy the Enterprise Developer Portal, with the sandbox dashboard registered as its `tyk-pro` provider. Implies `-p` |
| `-e` | EE gateway image (`tykio/tyk-gateway-ee`) |
| `-f` | FIPS images for every component. Can't be combined with `-e` |
| `-g <n>` | Number of gateway replicas |
| `-h` | HTTPS on the gateways, with the chart's default certificate (use `curl -k`) |
| `-G` | Deploy a sample gRPC plugin server and point the gateway's coprocess at it |
| `-E <file>` | Extra environment variables for every component (dashboard, gateway, pump, portal, MDCB). One `VAR=value` per line; `#` comments, blank lines and `export ` are allowed. Values can't contain spaces or commas |
| `-d <level>` | Log level for all components: `debug` (default), `info`, `warn` or `error` |
| `-H <version>` | Tyk helm chart version (default: the latest in your local helm repo index) |
| `-V <values.yaml>` | Install the Tyk chart with this values file instead. All other Tyk options (and `-H`) are ignored, but `-v` is still required and Redis/DB are still deployed |
| `-N <name>` | Namespace name instead of the next `hsandbox-N` |
| `-n` | Don't publish the sample APIs |
| `-o` | Create a Tyk Operator `OperatorContext` and publish the sample APIs as CRDs. Needs `hsbctl setup operator` first |
| `-D <GiB>` | MongoDB / PostgreSQL PVC size (default 5) |
| `-r <GiB>` | Redis PVC size (default 1) |
| `-s` | Enable the MDCB synchroniser. Use it on both the control plane and its data planes |
| `-T <tags>` | Data plane only: enable sharding with these comma-separated segment tags |
| `-R <sandbox>` | Create a data plane attached to this `tyk-control-plane` sandbox. Implies `-C tyk-data-plane` |
| `-M <host:port> -K <key> -O <org id> [-S]` | Create a data plane attached to an external MDCB (all three are required; `-S` uses SSL). `-K` is a dashboard user API key and `-O` the org ID |

The [Common tasks](#common-tasks) section has recipes.

### info / version

```
hsbctl info [sandbox...]      # versions, pods, URLs, connection commands, admin key, org ID
hsbctl info monitoring        # the Grafana URL (if 'setup monitoring' has been run)
hsbctl version [sandbox...]   # the image of every Deployment
```

`info` prints DB and Redis passwords and the admin key. Redact them before sharing the output.
For a data plane, `info` shows which control plane it's attached to.

### get

Prints a single value, for use in scripts:

```
hsbctl get <sandbox> <item>
```

| Item | Output |
|---|---|
| `dashboard`, `gateway` | URL with trailing `/` |
| `grafana` | Grafana URL (any existing namespace works as `<sandbox>`, e.g. `get monitoring grafana`) |
| `key` (or `admin`) | Dashboard admin user's API key |
| `orgid` | Org ID |
| `portal` | Developer portal URL (sandboxes created with `-P`) |
| `portal-token` | Developer portal admin's API token, for the portal admin API (`/portal-api`) |
| `mdcb` | MDCB `host:port` (control plane only) |
| `redis` | A `REDISCLI_AUTH=... redis-cli -h ... -p ...` command line |
| `redis-password`, `redis-port` | Those values alone |
| `mongo` | MongoDB connection URL |
| `postgres` | A `PGPASSWORD=... psql ...` command line |
| `chart`, `description`, `release` | From `sandbox-details` |
| `values` | `helm get values` for the Tyk release |

`key`, `orgid`, `mongo` and `postgres` only exist for `tyk-stack` and `tyk-control-plane`. An
item that doesn't apply prints an error on stderr and exits 1.

### publish

```
hsbctl publish <sandbox> file1.yaml file2.json ...
```

Loads API definitions into the dashboard (tyk-stack and tyk-control-plane only). It works out
the format from the file: Tyk OAS (JSON or YAML), plain OpenAPI YAML (imported as a new Tyk OAS
API), a classic `api_definition` payload, or a raw classic definition exported from the
dashboard.

### logs / shell / monitor

```
hsbctl logs <sandbox> <pod-name-part>      # kubectl logs -f of the first matching pod
hsbctl shell <sandbox> <pod-name-part>     # interactive shell in each matching pod
hsbctl monitor <sandbox> <pod-name-part>   # kubectl top for the pod every 60s, until Ctrl-C
```

The Tyk images are mostly distroless, so use the bastion for tools: `hsbctl shell 1 bastion`
opens bash with `TYK_KEY`, `TYK_ORG`, `TYK_DSHB` and `TYK_GW` set to the admin key, org ID and
in-cluster dashboard and gateway URLs.

### modify

```
hsbctl modify <sandbox> <deployment-name-part> -c <replicas>
hsbctl modify <sandbox> <deployment-name-part> -v <image-tag>
```

Changes a Deployment's replica count, or its image tag (a `v` is added if missing; the tag isn't
checked). The name part must match exactly one Deployment. It waits for the rollout. Because it
edits the Deployment directly, a later `helm upgrade` undoes it.

### delete / rm

```
hsbctl delete <sandbox...>
```

Deletes the namespace and everything in it, after removing any Tyk Operator resources, then
removes Released PVs. There is **no confirmation**. Deleting a control plane doesn't touch the
data planes attached to it; delete those too.

### setup

```
hsbctl setup operator      # install Tyk Operator into tyk-operator-system (HSBX_OPERATOR_VERSION to pin)
hsbctl setup monitoring    # install Prometheus + Grafana into 'monitoring', with the Tyk dashboards
```

Both are cluster-wide and done once. See [Monitoring](#monitoring-with-prometheus-and-grafana)
and [Tyk Operator](#manage-apis-with-tyk-operator).

### init / start

`init` sets up the cluster ([Installation](#set-up-the-cluster-hsbctl-init)). `start` starts a
stopped minikube cluster. With minikube, `hsbctl -C <profile> <command>` targets another
minikube profile (not tested recently).

---

## Common tasks

### Reproduce on a specific version

```sh
grep '^5.8.20,' ~/code/helm-sandbox/tyk-versions.list      # check the row exists
hsbctl create -v 5.8.20 -t "TT-12345 on customer version"
hsbctl create -v 5.8.20 -p -t "TT-12345 with postgres"     # same, but on PostgreSQL
```

### Compare two versions side by side

```sh
hsbctl create -v 5.8.20 -t "TT-12345 before"
hsbctl create -v 5.16.3 -t "TT-12345 after"
hsbctl version
```

### Control plane and data planes (MDCB)

```sh
hsbctl create -v 5.16.3 -C tyk-control-plane -s -t "TT-12345 CP"           # say this is hsandbox-2
hsbctl create -v 5.16.3 -R 2 -s -g 2 -T edge1 -t "TT-12345 DP edge1"
hsbctl create -v 5.16.3 -R 2 -s -T edge2 -t "TT-12345 DP edge2"
```

Each data plane gets its own MDCB group ID. APIs created on the control plane's dashboard load
on the data plane gateways (with sharding, only those tagged `edge1` or `edge2`). Drop `-s` and
`-T` if you don't need the synchroniser or sharding. Use `-M`/`-K`/`-O` instead of `-R` to attach
a data plane to an MDCB outside this cluster.

### Publish your own APIs

```sh
hsbctl publish 1 my-api-oas.yaml exported-classic-api.json
```

Or use the dashboard UI, or its API with `Authorization: $(hsbctl get 1 key)`.

### Override settings with environment variables

Every Tyk setting can be set with an environment variable: `TYK_GW_*` for the gateway,
`TYK_DB_*` for the dashboard, `TYK_PMP_*` for the pump, `TYK_MDCB_*` for MDCB and `PORTAL_*` for
the portal. Each component simply ignores variables meant for the others.

```sh
cat > /tmp/env.list <<'EOF'
# comments and blank lines are fine
TYK_GW_HTTPSERVEROPTIONS_ENABLEHTTP2=true
TYK_DB_NOTIFYONCHANGE=false
EOF
hsbctl create -v 5.16.3 -E /tmp/env.list -t "http2 test"
```

To change a running sandbox, use `kubectl set env deploy/<name> -n hsandbox-N VAR=value`, or
`helm upgrade --reuse-values --set ...` on the Tyk release.

### Use your own values file

```sh
hsbctl get 1 values > my-values.yaml          # start from what hsbctl deploys
vi my-values.yaml
hsbctl create -v 5.16.3 -V my-values.yaml -t "custom values"
```

With `-V`, hsbctl still creates Redis, MongoDB (or PostgreSQL with `-p`), the secrets, the
bastion and httpbin. Then it runs `helm upgrade --install -f <file>` for the chart chosen with
`-C`. Your values file must point at those services and secrets.

### Load a plugin bundle

```sh
cp bundle.zip ~/.tyk/plugins/5.16.3-1/        # directory = gateway column of the versions row
```

Then reference the bundle by name in the API definition. In classic, set
`"custom_middleware_bundle": "bundle.zip"`. In Tyk OAS, set
`x-tyk-api-gateway.middleware.global.pluginConfig.bundle` to `{enabled: true, path: bundle.zip}`. Every sandbox
using that gateway version shares the directory. On minikube, `~/.tyk/plugins` is mounted into
the node by `init`.

For gRPC plugins, `create -G` deploys a sample gRPC server (`mangomm/tyk-grpc-plugin`) and
configures the gateway to use it.

### Change a component's version or scale it

```sh
hsbctl modify 1 gateway -v 5.16.0       # roll the gateway back to v5.16.0
hsbctl modify 1 gateway -c 3            # three gateway pods
```

For a test of the real upgrade path, run `helm upgrade` on the Tyk release instead (see
`hsbctl get 1 values` and `hsbctl get 1 release`).

### Talk to Redis, MongoDB and PostgreSQL

```sh
eval "$(hsbctl get 1 redis) --scan --pattern 'apikey-*'"
mongosh "$(hsbctl get 1 mongo)" --eval 'db.tyk_apis.countDocuments()'
eval "$(hsbctl get 1 postgres) -c '\dt'"
```

From the bastion (`hsbctl shell 1 bastion`), use the service names instead.
`redis-cli -h tyk-redis-master` needs `REDISCLI_AUTH` set to the output of
`hsbctl get 1 redis-password`. MongoDB is `tyk-mongo-mongodb:27017` and PostgreSQL is
`tyk-postgres-postgresql:5432`.

### Use the Enterprise Developer Portal

```sh
hsbctl create -v 5.16.3 -P -t "portal test"
hsbctl info N            # shows the portal URL
```

The portal's admin user details are in the secret `secrets-tykstack-tyk-dev-portal`
(`adminUserEmail`, `adminUserPassword`).

`create` also registers the sandbox's dashboard in the portal as a `tyk-pro` provider named
`Tyk Dashboard`, using the in-cluster dashboard and gateway URLs, the dashboard admin's API key and
the org ID, so its policies are synchronised straight away. The portal admin's API token (printed
by the chart's `dev-portal-job-*` bootstrap job) is kept in `sandbox-details` and drives the portal
admin API:

```sh
TOKEN=$(hsbctl get N portal-token); PORTAL=$(hsbctl get N portal)
curl -s -H "Authorization: $TOKEN" ${PORTAL}portal-api/providers | jq
```

If the provider step fails, `create` prints a `[WARN]` and carries on; add the provider in the
portal UI (**Settings > Providers**) instead.

### Manage APIs with Tyk Operator

```sh
hsbctl setup operator                          # once per cluster. Uses SBX_LICENSE
hsbctl create -v 5.16.3 -o -t "operator test"  # creates OperatorContext 'local-operator-context'
kubectl get apidefinitions -n hsandbox-N
```

`-o` publishes `APIs/CRDs/*.yaml` as CRDs, pointing at the sandbox's OperatorContext. It works
with `tyk-stack` and `tyk-control-plane` only.

### Monitoring with Prometheus and Grafana

```sh
hsbctl setup monitoring          # once per cluster. Rerun to upgrade
hsbctl get monitoring grafana    # the URL. Log in with SBX_USER and its password
```

This installs kube-prometheus-stack into the `monitoring` namespace. Pod CPU and memory work
straight away: see **Dashboards → Kubernetes / Compute Resources / Namespace (Pods)** and pick a
sandbox namespace. It also loads the Tyk Grafana dashboards (folder **Tyk**) from
[tyk-install](https://github.com/TykTechnologies/tyk-install/tree/main/observability). Those
dashboards stay empty unless the Tyk components export OpenTelemetry metrics into Prometheus,
which hsbctl doesn't set up.

`hsbctl monitor <sandbox> <pod>` is a lighter alternative: it prints `kubectl top` for one pod
every minute.

---

## Adding a new Tyk version

1. Find the versions released together, from Tyk's release notes and the image tags on Docker
   Hub (`tykio/tyk-gateway`, `tykio/tyk-dashboard`, `tykio/tyk-pump-docker-pub`,
   `tykio/tyk-mdcb-docker`, `tykio/portal`).
2. Add a row to `tyk-versions.list` under its `# X.Y` heading, newest first:
   ```
   5.16.4,5.16.4-1,5.16.4-1,1.18.0-1,1.8.4-1,2.3.0-1,2.14.0-1,1.20.1-1
   ```
   The refNo **must not contain `-`** (`5.16.4rc1` is fine, `5.16.4-rc1` isn't). Keep the `-1`
   suffix on each version.
3. `hsbctl create -v 5.16.4 -t "check 5.16.4"`. A wrong version shows up as pods in
   `ImagePullBackOff`.

New Tyk **chart** releases are a separate matter: run `helm repo update` to get the latest charts.
hsbctl doesn't update the repo index itself.

## Running on AWS EC2

The `EC2/` scripts set up an Ubuntu EC2 instance to run sandboxes:

```sh
EC2/aws-setup <instance hostname or ssh alias>
```

`aws-setup` runs on your machine. It copies your `~/.tyk-sandbox`, `~/.ssh/config` and a few
dotfiles to the instance. Then it runs `ubuntu-deploy-sandboxes` there, which installs the
packages, Docker and helm, clones this repo (and related ones) and runs `hsbctl init`.

On EC2, the host IP that hsbctl detects is the instance's private VPC address. hsbctl detects
EC2 (from the DMI board vendor), so `info` also prints `localhost` URLs and an ssh command for
every sandbox:

```
hsandbox-1.ssh                ssh -g -L 32275:10.0.1.23:32275 -L 32695:10.0.1.23:32695 ... <aws hostname>
```

Run that command **on your laptop**, replacing `<aws hostname>`. Then use the `localhost` URLs.

---

## Troubleshooting

| Symptom | Things to check |
|---|---|
| `create` hangs at "Waiting for statefulset/deployment" | `kubectl get pods,pvc -n hsandbox-N`. A pending PVC means there's no default StorageClass. A pod stuck pulling means a network or Docker Hub rate-limit problem |
| `create` fails during the Tyk helm install | The bootstrap jobs failed: `kubectl get jobs -n hsandbox-N`, then `kubectl logs job/<name> -n hsandbox-N`. Usually a missing or expired `SBX_LICENSE` (or `SBX_MDCB_LICENSE` for a control plane) |
| `get key` / `orgid` empty, or `AdminKey: null` | `redis-cli` isn't installed on the host, or the bootstrap didn't create the admin user. Check the bootstrap job logs |
| `[FATAL]Unable to find '<ver>' in ...tyk-versions.list` | Add the row: [Adding a new Tyk version](#adding-a-new-tyk-version) |
| Pods in `ImagePullBackOff` | The version doesn't exist as an image tag (check the row), or Docker Hub rate limiting |
| Bastion pod in `ErrImageNeverPull` / `ImagePullBackOff` | The local bastion image is missing. Run `tbi/k3s-build-bastion.sh` (or `tbi/minikube-build-bastion.sh`) |
| `-H <version>` not found, or a new chart version is missing | `helm repo update`, then `helm search repo tyk-helm/tyk-stack --versions` |
| Sample APIs return 5xx | Check the httpbin pod. From the bastion, `curl http://httpbin.org/anything` should show a private `origin` address (the local pod). `getent hosts httpbin.org` may show the public IPv6 address even when it works |
| Data plane gateways don't load APIs | `kubectl logs deploy/gateway-tykdataplane-tyk-gateway -n <dp>`: look for RPC/MDCB errors. Check the control plane's MDCB: `curl http://<ip>:<mdcb health port>/health` from `info` |
| `kubectl` talks to the wrong cluster, or "connection refused" | `KUBECONFIG` isn't set: `source ~/.bashrc` after `init` |
| "too many open files" or pods crash-looping with many sandboxes | Raise the inotify limits: `sysctl -w fs.inotify.max_user_watches=...` and `fs.inotify.max_user_instances=...` |
| A `modify` change disappeared | A `helm upgrade` reverted it. Put the change in helm values instead |

## Known limitations

- `_ee` and `_fips` rows in `tyk-versions.list` don't work with hsbctl. Use `-e` / `-f` with the
  plain row.
- `-E` values can't contain spaces or commas.
- The OSS `tyk-oss` chart and standalone gateways aren't supported.
- `get` has no item for a data plane's gateway secret (it's `Secret`).

## AI coding agents

Two files help AI coding agents such as Claude Code or Codex. They split the job in two: one is
for changing the repo, the other for using `hsbctl`.

- **`AGENTS.md`** is for agents that **change the repo**. It covers how `create` and the other
  subcommands fit together, the coding conventions, how to check changes, safety rules and
  known issues. Many agent tools read `AGENTS.md` automatically. For Claude Code, `CLAUDE.md`
  imports it.
- **`skills/SKILL.md`** is a Claude Code skill for **using** `hsbctl`. It covers creating and
  deleting sandboxes, getting URLs and keys, publishing APIs, loading plugins and monitoring.
  Claude Code doesn't load it from the repo automatically. Install it for your user with
  `mkdir -p ~/.claude/skills/hsbctl && cp skills/SKILL.md ~/.claude/skills/hsbctl/`.

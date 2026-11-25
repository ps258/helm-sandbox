# AGENTS.md — helm-sandbox

`hsbctl` deploys Tyk test environments ("helm sandboxes") onto a local k3s or minikube cluster.
It uses the official Tyk helm charts (`tyk-stack`, `tyk-control-plane`, `tyk-data-plane`). Each
sandbox is a namespace, `hsandbox-N`, labelled `creator=hsbctl`. The namespace holds its own
Redis and Mongo or Postgres (bitnami charts), a `bastion` debug pod that also serves plugin
bundles, and an `httpbin` pod for local upstream traffic. The tool is used for reproducing
support tickets on specific Tyk versions. `README.md` is the user guide, and `skills/SKILL.md`
explains how to *use* hsbctl. This file is for *changing* the repo.

## Layout

| Path | What it is |
|---|---|
| `hsbctl` | The CLI. **ksh** (`#!/bin/ksh`), runs on the host. The `case $1 in` block at the end routes each subcommand. `help()` near the top is the usage text |
| `tyk-versions.list` | Each row is a refNo followed by the version of every component. `create -v` reads it. It is also the record of which versions shipped together |
| `YAML/` | Templates for the bastion, httpbin and gRPC plugin pods. They go through `envsubst`, so they can use exported variables such as `HSBX_NS` and `HSBX_PLUGIN_PATH`. `applyYAMLtemplate` applies them |
| `APIs/` | Sample APIs that `create` publishes (`APIs/*.yaml`) unless `-n` is given. `APIs/CRDs/*.yaml` are published through Tyk Operator instead, with `-o` |
| `etc/kube-prometheus-stack-values.yaml` | Values for `hsbctl setup monitoring` |
| `etc/tmp.conf` | minikube only: copied into the node by `init` so persistent volumes for the databases can be created |
| `tbi/` | Builds the bastion image `saintpeter/bastion-9:latest` and imports it into k3s or minikube. The image is local only and can't be pulled from a registry. `setup/` holds the files baked into it |
| `EC2/` | `aws-setup` and `ubuntu-deploy-sandboxes` provision an EC2 host to run sandboxes on |
| `operator/` | Unused 2023 copies of `APIs/CRDs/` (identical files) |
| `setup-monitoring` | Legacy script, superseded by `hsbctl setup monitoring` |
| `skills/SKILL.md` | Claude Code skill for using hsbctl. The installed copy is `~/.claude/skills/hsbctl/SKILL.md` |
| `AGENTS.md`, `CLAUDE.md` | This file. `CLAUDE.md` only contains `@AGENTS.md`, so Claude Code loads this file too. Edit this file, not `CLAUDE.md` |

The repo root also has many **untracked scratch files** that the author keeps there:
`values-*.yaml`, `bitnami-*.yaml`, `file.*`, `env.txt`, `1.2.0/` and others. Leave them
alone. Never `git add -A` or `git add .`; add files by name.

## How `create` works

1. Options are parsed with `getopts`. Most of them only build up `HELM_SET_*` strings of
   `--set` arguments. `-R`/`-M`/`-K`/`-O` force the chart to `tyk-data-plane` *after* parsing.
   Anything that depends on the final chart, such as the `-E` file, must run after that point.
2. `loadVersions` reads the `-v` row. Gateway, dashboard and pump tags become `v<col>` with the
   trailing `-1` removed. The plugin directory is the **raw** gateway column, e.g.
   `~/.tyk/plugins/5.13.6-1`.
3. `createNamespace` writes the **`sandbox-details` ConfigMap**. That is the sandbox's only
   saved state: versions, chart, DB type, description, HTTPS flag, and for a data plane its
   control plane (`HSBX_CP`). Later, `saveOrgAndAdminKey` adds `HSBX_ADMIN_KEY` and
   `HSBX_ORGID`. It reads them with `redis-cli` from the host, via the Redis NodePort.
4. Redis, the bastion, httpbin (and the gRPC pod with `-G`) are deployed, then Mongo or
   Postgres. Secrets are created, then `runHelm` runs the install. `runHelm` has one helm
   command for stack/control plane, one for data plane, and one for `-V`. A new `--set`
   generally has to be added to the right one of these, or to both.
5. Sample APIs are published, then the same report as `info` is printed.

Consequences:
- `info`, `get`, `publish` and `shell` work everything out from `sandbox-details` and the
  service NodePorts. A new piece of per-sandbox data has to be written to that ConfigMap at
  create time. Sandboxes that already exist won't have it, so handle the `null`.
- Release names are fixed: `tykstack`, `tykcontrolplane`, `tykdataplane`. Service names come
  from them, e.g. `dashboard-svc-<release>-tyk-dashboard`.
- extraEnvs are built as indexed `--set …extraEnvs[N]` pairs, with one counter per component
  (`setExtraEnvs<Component>`). Always add them through those functions.
- The `HELM_SET_*` strings are expanded **unquoted**. A value containing spaces gets split, and
  helm treats a comma as a list separator. Escape commas as `\,`, as `-T` does.
- `modify` edits Deployments directly, so a later `helm upgrade` reverts the change.

## Conventions

- ksh: declare function-local variables with `typeset`, use `[[ ]]` tests, indent two spaces,
  and prefix messages with `[INFO]`/`[WARN]`/`[FATAL]`. Avoid GNU-only flags where you
  reasonably can (see the macOS `sed -i` workaround in `modify`).
- `get` output is captured by scripts (`KEY=$(hsbctl get 1 key)`). Its errors go to **stderr
  with `exit 1`**, never to stdout.
- When a subcommand or option changes, keep four things in step:
  - `help()` in `hsbctl`.
  - The copy of the help text in `README.md`, which is pasted verbatim.
  - `skills/SKILL.md`.
  - The installed skill: copy `skills/SKILL.md` to `~/.claude/skills/hsbctl/SKILL.md`.
- `tyk-versions.list`:
  - Format: `refNo,gateway,dashboard,pump,tib,sync,mdcb,portal`, the same as tyk-sandbox's.
  - **A refNo must not contain `-`.**
  - Keep rows under their `# X.Y` heading, newest first, with the companion versions that were
    current at release.
  - `_ee`/`_fips` rows don't work in hsbctl (see Known issues); `-e`/`-f` do that job.
- Commits go **straight to main**, no branches. Message format is `<file(s)>: <what changed>`,
  lowercase, e.g. `tyk-versions.list: added 5.13.6 and 5.16.3`, `hsbctl: implemented the "get
  grafana" subcommand`. Keep one logical change per commit. The author sometimes wants to
  review a diff before it is committed; ask when in doubt.

## Checking changes

There is no test suite.
- **Syntax:** `ksh -n hsbctl`. It prints many "obsolete" warnings for code that is already
  there. Ignore them; only a non-zero exit or a new error matters.
- **Testing a single function:** extract it and stub what it calls, e.g.
  `sed -n '/^function setExtraEnvsFromFile/,/^}/p' hsbctl`. Then run it under `ksh`.
- **Safe to run against the live cluster (read-only):** `./hsbctl info`, `./hsbctl version`,
  `./hsbctl get <ns> …`, `kubectl get …`, `helm get values …`. Use `./hsbctl` so you run the
  working copy, not the one on `PATH`.
- **End to end:**
  1. Run `./hsbctl create -v <ver> -t "test <change>"` in the background. It takes several
     minutes.
  2. Check `./hsbctl info <ns>`, the pods, and `helm get values`.
  3. Curl the dashboard and gateway.
  4. Delete only the sandboxes you created.
  - Control/data plane changes need a pair: `-C tyk-control-plane`, then `-R <cp>`.

## Safety

- `~/.tyk-sandbox` holds Tyk and MDCB licences. Never print it, commit it, or copy it into the
  repo. `info` output and `get redis`/`get postgres`/`get mongo` include passwords and the admin
  key.
- **The repo is public on GitHub.** Don't commit customer data, ticket attachments, licences,
  or the scratch files at the root.
- Sandboxes and the `monitoring` / `tyk-operator-system` namespaces may belong to live
  investigations. Only delete what you created or were told to delete. `hsbctl delete` doesn't
  ask for confirmation.
- `hsbctl init` installs k3s or minikube with sudo and edits `~/.bashrc`. `setup operator`,
  `setup monitoring` and the `tbi/*-build-bastion.sh` scripts change the whole cluster. Don't
  run any of them unless asked.

## Known issues (not yet fixed)

- `_ee`/`_fips` rows in `tyk-versions.list` don't work in hsbctl. `HSBX_GATE_EE` is set in
  `loadVersions` but never used, and the `fips-` prefix isn't removed, which gives
  `vfips-X.Y.Z` tags.
- `-E` values can't contain spaces or commas (see the unquoted `HELM_SET_*` above).
- `get <ns> postgres` on a Mongo sandbox (and on a data plane) says "Not mongodb" / "doesn't use
  mongodb": the messages were copied from the mongo branch.
- `FIXME`s in `get`: data-plane gateway secret; separate port/password options for mongo and
  postgres.

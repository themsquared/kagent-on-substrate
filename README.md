# kagent on Agent Substrate

Companion repo for the post *kagent on Agent Substrate: runtime vs scheduling* (link added when the post publishes).

**kagent is the runtime.** It defines agents as Kubernetes resources and runs the agent loop.
**Agent Substrate is not a runtime.** It is the layer underneath that decides where work runs and
routes requests to it: placement, many actors multiplexed onto workers, snapshot and restore,
request parking.

This repo makes that split concrete with one `AgentTemplate`, two `Harness`es, and two
`WorkerPool`s on a local kind cluster. You can see which half owns what with `kagent` and
`kubectl ate`. The ownership table is in [docs/ownership.md](docs/ownership.md).

```
                     you / A2A client / UI
                              |
                 +------------v-------------+
   kagent        |  Agent -> Harness engine |   defines the agent, runs the loop,
   (runtime)     |  Session, tools (MCP)    |   owns the conversation and the front door
                 +------------+-------------+
                              |  Harness.spec.substrate.workerPoolRef
                 +------------v-------------+
   Agent         |  atenet-router           |   routes to the actor, parks while full
   Substrate     |  Scheduler, WorkerPool   |   places actors on workers, suspend/resume
   (scheduling)  |  snapshots, egress       |   no idea what an "agent loop" is
                 +--------------------------+
```

## What is verified, and how

| Claim | Status |
|---|---|
| Every manifest is accepted by the real kagent 1.0.1 and Substrate 1.0.0 CRDs, including their CEL rules | **Verified.** `make validate` runs a throwaway kube-apiserver v1.37.0 (envtest binaries) and `kubectl apply --dry-run=server`. Six negative manifests that must be rejected are rejected |
| `install/*.yaml` is read by the installer and reaches the charts | **Verified** with `kagent install --dry-run` (kagent CLI v1.0.1): read-only tools values and `atenetRouter.requestParking.budget` appear in the rendered values |
| The demo runs end to end on kind | **Not run by the author.** The authoring machine had no Docker. The commands are the documented ones, but you are the first live run. Open an issue with the output if something differs |
| Substrate behaviour described below (placement, parking, suspend/resume) | Taken from the docs linked inline. Not measured here |

## Prerequisites

- Docker, [kind](https://kind.sigs.k8s.io/) v0.32.0 or later (Kubernetes 1.37 is required by Agent Substrate)
- `kubectl`, `helm` 3, `jq`
- the `kagent` CLI, same version as the release you install: `curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash -s -- --version v1.0.1`
- `OPENAI_API_KEY` exported in your shell. The installer reads it and stores it in a cluster Secret. It never touches this repo

`make tools` checks the CLIs.

## Walkthrough

### 1. Create the cluster

```bash
make cluster
```

[cluster/kind-config.yaml](cluster/kind-config.yaml) is one control-plane node on `kindest/node:v1.37.0`.
The kagent docs say no API server changes are needed
([install guide](https://kagent.dev/docs/kagent/1.x/setup/installation/)).

### 2. Install kagent (OSS)

```bash
export OPENAI_API_KEY=...        # your key
make install
```

`kagent install` installs the CRDs, Agent Substrate into `ate-system`, the Substrate PodCertificate
controller, a development PostgreSQL, and kagent, in order. It takes chart values only through a CLI
config file, so [install/kagent-config.yaml](install/kagent-config.yaml) points at two values files:

- [install/kagent-values.yaml](install/kagent-values.yaml): `kagent-tools` runs read-only, with a
  read-only ClusterRole, so a demo triage agent cannot change your cluster.
- [install/substrate-values.yaml](install/substrate-values.yaml): shows the request parking knob,
  `atenetRouter.requestParking.budget`. `60s` is the chart default; the router binary's own flag
  default is `5s`.

The dev PostgreSQL is for evaluation. The installer does not enable pgvector, so long-term memory is off.

You now have the stock `kagent-default` WorkerPool. Check it:

```bash
kubectl get workerpools -n kagent
```

### 3. Install the kubectl-ate plugin

```bash
make ate-cli        # downloads kubectl-ate from the v1.0.0 Substrate release, uses sudo to move it
kubectl ate get workers
```

`kubectl ate` is Substrate's CLI. It talks to `ate-api-server` (it opens a port-forward for you).
Notice what it lists: workers and actors. Not agents.

### 4. Apply the pools, the harnesses, the template, the agents

```bash
make apply
```

Read the manifests in order. They are short and commented.

| File | Owner | What it says |
|---|---|---|
| [manifests/10-workerpools.yaml](manifests/10-workerpools.yaml) | Substrate (`ate.dev/v1`) | Two pools: `interactive` (2 workers, up to 4 CPU and 6Gi each) and `batch` (1 worker, up to 2 CPU and 3Gi). Capacity only |
| [manifests/20-harnesses.yaml](manifests/20-harnesses.yaml) | kagent | Two Harnesses on the same engine (`spec.kagent`). The only difference is `workerPoolRef` |
| [manifests/30-agenttemplate.yaml](manifests/30-agenttemplate.yaml) | kagent | The agent itself: model, system prompt, four read-only Kubernetes tools from the built-in MCP server |
| [manifests/40-agents.yaml](manifests/40-agents.yaml) | kagent | Two Agents pair that one template with each Harness |

The pairing is the point. Same agent definition, two placement domains. kagent decides which pool
an agent may use. It does not decide which worker.

Two details that matter and are easy to miss:

- Every pool that backs a Harness must carry the labels `kagent.dev/worker-pool-name` and
  `kagent.dev/worker-pool-namespace`. kagent compiles each ActorTemplate with a worker selector on them.
  ([kagent architecture: configuration and compilation](https://github.com/kagent-dev/kagent/blob/v1.0.1/docs/architecture/configuration-and-compilation.md))
- An `Agent` is not `Ready` until kagent has compiled a revision and built a golden snapshot of the
  runtime. That can take a minute. `make apply` waits for it.

Optional extras in [examples/](examples/): a second `ModelConfig` and a custom `RemoteMCPServer`.

### 5. Run the demo

```bash
make demo
```

[scripts/demo.sh](scripts/demo.sh) does this, printing the real output of each command:

1. Lists the pools and workers (capacity).
2. Creates a Session on `triage-interactive`. Substrate starts an actor on the `interactive` pool.
3. Sends one turn. kagent runs the loop. Substrate routed the request and resumed the actor.
4. Shows the actor after the turn. kagent suspends at each turn boundary, so the worker is free again.
   The next message resumes the actor.
5. Bursts `BURST` (default 6) Sessions at the small `batch` pool.
6. Sends a message to the interactive Session during the burst.

Things to look for, per the docs (not guaranteed timings):

- `kubectl ate get workers` shows ACTORS and CPU and memory allocated against capacity per worker.
  Placement is a free actor slot plus a CPU and memory check, then power-of-two-choices sampling.
  ([Solo Substrate runtime docs](https://docs.solo.io/kagent/latest/about/substrate-runtime/))
- When the batch pool has no room, the router parks the request up to the budget instead of
  rejecting it immediately. The `interactive` pool is a different placement domain and is not in that queue.
  ([request parking](https://github.com/kagent-dev/substrate/blob/v1.0.1/docs/concepts/request-parking.md))

### Watching it

```bash
make status
kubectl ate get actors -a kagent     # actors live in an atespace named after the Agent's namespace
kubectl ate get workers
```

Parking is observable as `atenet.router.parking.active`, `atenet.router.parking.wait.duration` and
`atenet.router.parking.rejected` on the router, and as a "Request Parking" card on its `/statusz` page. See
the [request parking doc](https://github.com/kagent-dev/substrate/blob/v1.0.1/docs/concepts/request-parking.md).
Worker pool metrics: `ate.workerpool.workers`, `ate.workerpool.desired_workers`, `ate.workerpool.ready_workers`.

### 6. Clean up

```bash
make clean      # sessions, then the resources this repo applied
make destroy    # delete the kind cluster
```

## What Substrate does not do here

The docs describe placement, suspend/resume, routing and parking. They do not describe a priority
or fairness policy, quotas per team, or any ordering among parked requests beyond the budget. This
repo does not pretend otherwise. Separating pools, as the two Harnesses do, is the isolation tool
the docs give you.

## Enterprise path

This repo installs the open source kagent 1.0.x. Solo Enterprise for kagent uses the same
`api.kagent.dev/v1alpha3` model (Harness, AgentTemplate, Agent) on the same Substrate layer. Install it
from the enterprise guide instead of step 2:
<https://docs.solo.io/kagent/latest/setup/installation/>. Then continue from step 4.

Two things to check against that guide on an enterprise build, because they were not run here:
the Harness runtime image (the enterprise docs show `workload.image` pinned by digest; these
manifests omit `workload` and use the release's built-in image), and the name of the stock
WorkerPool and its ServiceAccount (`kagent-default` in the OSS chart).

## Versions

| Thing | Version | Where it comes from |
|---|---|---|
| kagent CLI and chart | 1.0.1 | `install.kagent` default in CLI v1.0.1 |
| Agent Substrate chart | 1.0.0 | `install.substrate` default in CLI v1.0.1 |
| Kubernetes | 1.37 | `kindest/node:v1.37.0`, required by Substrate (PodCertificateRequest, ClusterTrustBundle GA) |
| API groups | `api.kagent.dev/v1alpha3`, `ate.dev/v1` | CRDs from the two CRD charts |

The kagent 0.x group `kagent.dev` is a different API with no upgrade path to 1.x.

## License

Apache-2.0. See [LICENSE](LICENSE).

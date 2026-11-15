# Who owns what

The rule this repo is built to show: **kagent is the runtime. Agent Substrate is the
scheduling and routing layer underneath it.** Substrate does not know what an agent loop is.
kagent does not pick workers.

| Concern | kagent (runtime) | Agent Substrate (placement and routing) |
|---|---|---|
| What an agent is | `Agent`, `AgentTemplate`, `Harness` CRs (`api.kagent.dev/v1alpha3`) | Nothing. It runs OCI workloads and has no agent concept |
| The agent loop (model calls, tool calls, memory) | The Harness engine (`spec.kagent`, `codex`, `claude`, or `byo`) | Not involved |
| Conversation state | `Session` (gRPC and PostgreSQL object, not a CRD) and its append-only transcript | Not involved |
| Front door | A2A and MCP gateway on the controller, `/agents/{ns}/{name}` | Not involved |
| Tools | `RemoteMCPServer`, tool lists in the `AgentTemplate` | Egress gateway injects credentials on outbound calls |
| Which pool an agent may use | `Harness.spec.substrate.workerPoolRef` | Reads the pool it is told about |
| Pool capacity | Nothing | `WorkerPool` (`ate.dev/v1`): replicas, worker image, sandbox class, worker CPU and memory |
| Which worker an actor lands on | Nothing | Scheduler in `ate-api-server`: a free actor slot plus a CPU and memory check, then power-of-two-choices sampling |
| Suspend and resume | Suspends at every turn boundary, resumes on the next message | Snapshot and restore of the actor, golden snapshot per ActorTemplate |
| Routing a request to the right actor | Addresses the Session's actor by name (`session-<id>`) in an atespace named after the Agent's namespace | `atenet-router` resolves and forwards; parks a request while the pool is full |
| Priority, fairness, cross-team policy | Not a documented kagent feature | **Not documented as a Substrate feature either.** Do not assume it exists |

Sources: kagent 1.x docs ([core concepts](https://kagent.dev/docs/kagent/1.x/about/core-concepts/),
[suspend and resume](https://kagent.dev/docs/kagent/1.x/about/substrate-runtime/suspend-and-resume/)),
the kagent v1.0.1 repo (`docs/architecture/`), and the Agent Substrate v1.0.x repo
(`docs/concepts/architecture.md`, `docs/concepts/request-parking.md`).

## The common mistake

Treating Substrate as the thing that runs your agent. If you catch yourself writing "deploy the
agent to Substrate", step back: you deploy an `Agent` to kagent. kagent compiles it into an
ActorTemplate and Substrate decides where its actors run.

## Terminology

Both projects' docs use the word "runtime" loosely. In this repo "agent runtime" means the
Harness engine that executes the agent loop. Substrate is the compute, placement and routing
layer that engine runs on.

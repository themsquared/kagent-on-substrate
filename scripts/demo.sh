#!/usr/bin/env bash
# Demo: one AgentTemplate, two Harnesses, two WorkerPools.
#
#   kagent   = the runtime. It owns the Agent, the loop, the Session and the front door.
#   Substrate = placement and routing. It picks a worker, resumes the actor, parks the request.
#
# Needs the cluster from `make cluster install apply` and the kubectl-ate plugin (`make ate-cli`).
# Everything this script prints comes from the real CLIs. It asserts nothing about timing.
set -euo pipefail

NS="${NAMESPACE:-kagent}"
BURST="${BURST:-6}"
TASK_TRIAGE='Use your tools. List pods in the kube-system namespace and say in two sentences whether any look unhealthy.'

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
for t in kubectl kagent jq; do need "$t"; done
kubectl ate --help >/dev/null 2>&1 || { echo "missing kubectl-ate plugin: run 'make ate-cli'"; exit 1; }

new_session() { kagent agent session create --agent "$1" -n "$NS" -o json | jq -r '.session.id'; }

SESSIONS=()
cleanup() { for s in "${SESSIONS[@]:-}"; do [ -n "$s" ] && kagent agent session delete "$s" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

say "1. The pools Substrate schedules onto (capacity, not agents)"
kubectl get workerpools -n "$NS"
kubectl ate get workers

say "2. kagent compiled each Agent into a revision; Ready means the golden snapshot exists"
kagent agent get triage-interactive
kagent agent get triage-batch

say "3. A Session is a kagent object. Its Actor is created suspended, so it holds no worker yet"
S_INT="$(new_session triage-interactive)"; SESSIONS+=("$S_INT")
echo "interactive session: $S_INT"
echo "-- actors (history: suspended entries stay behind). Occupancy is the workers list."
kubectl ate get actors -a "$NS"

say "4. One turn. kagent runs the loop; Substrate routed the request to the actor and resumed it"
kagent agent invoke --session "$S_INT" --task "$TASK_TRIAGE"

say "5. Turn finished: kagent suspends the actor and the worker is free again. Next message resumes it"
kubectl ate get actors -a "$NS"
kagent agent invoke --session "$S_INT" --task "What did I just ask you?"

say "6. Burst on the SMALL batch pool ($BURST sessions at once) while the interactive pool stays quiet"
pids=()
for i in $(seq 1 "$BURST"); do
  s="$(new_session triage-batch)"; SESSIONS+=("$s")
  kagent agent invoke --session "$s" --task "$TASK_TRIAGE" >"/tmp/kos-burst-$i.out" 2>&1 &
  pids+=($!)
done
sleep 5
echo "-- workers: ACTORS and CPU/MEMORY allocated vs capacity, per pool"
kubectl ate get workers
echo "-- actors"
kubectl ate get actors -a "$NS"

say "7. Interactive session, same moment: its own pool, so it is not queued behind the burst"
time kagent agent invoke --session "$S_INT" --task "Reply with the single word: ready"

wait "${pids[@]}" || true
say "8. Burst finished. Everything resumed and suspended without kagent touching placement"
kubectl ate get workers
echo
echo "Parking (the router holding a request until a worker is routable) is visible as the"
echo "atenet.router.parking.* metrics on atenet-router. See README, section 'Watching it'."

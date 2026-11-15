#!/usr/bin/env bash
# Validate every manifest in manifests/ against the real CRDs on a real kube-apiserver,
# with no cluster and no Docker. Server-side dry-run runs the CRD schemas AND the CEL
# validation rules (ExactlyOneOf, workerPoolRef must not be empty, and so on), which
# schema-only validators such as kubeconform do not evaluate.
#
# What it does:
#   1. helm pull the two CRD charts (versions pinned below)
#   2. fetch etcd + kube-apiserver + kubectl with setup-envtest
#   3. start them on localhost, install the CRDs
#   4. `kubectl apply --dry-run=server` every file in manifests/ and examples/ (must pass)
#   5. same for every file in hack/negative/                      (must be REJECTED)
#
# Needs: helm, openssl, python3, and go (for setup-envtest) or setup-envtest on PATH.
# Linux and macOS. Nothing is installed outside hack/.cache.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/hack/.cache"
KAGENT_CRDS_VERSION="${KAGENT_CRDS_VERSION:-1.0.1}"
SUBSTRATE_CRDS_VERSION="${SUBSTRATE_CRDS_VERSION:-1.0.0}"
export WORKER_IMAGE="${WORKER_IMAGE:-ghcr.io/kagent-dev/substrate/ateworker-gvisor:v1.0.0}"

mkdir -p "$CACHE"

if ! command -v setup-envtest >/dev/null 2>&1; then
  GOBIN="$CACHE/bin" go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
  export PATH="$CACHE/bin:$PATH"
fi
BIN="$(setup-envtest use -p path --bin-dir "$CACHE/envtest")"
echo "apiserver binaries: $BIN"

CRDS="$ROOT/hack/crds"
rm -rf "$CRDS"; mkdir -p "$CRDS"
helm pull oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version "$KAGENT_CRDS_VERSION" --untar --untardir "$CRDS"
helm pull oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds --version "$SUBSTRATE_CRDS_VERSION" --untar --untardir "$CRDS"

WORK="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill -KILL "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

# --- etcd + kube-apiserver -------------------------------------------------------
ETCD_PORT=23790; API_PORT=16443
"$BIN/etcd" --data-dir "$WORK/etcd" \
  --listen-client-urls "http://127.0.0.1:$ETCD_PORT" --advertise-client-urls "http://127.0.0.1:$ETCD_PORT" \
  --listen-peer-urls "http://127.0.0.1:$((ETCD_PORT+1))" >"$WORK/etcd.log" 2>&1 &
PIDS+=($!)

openssl genrsa -out "$WORK/sa.key" 2048 2>/dev/null
openssl rsa -in "$WORK/sa.key" -pubout -out "$WORK/sa.pub" 2>/dev/null
echo "validate-token,validator,1,system:masters" >"$WORK/tokens.csv"

"$BIN/kube-apiserver" \
  --etcd-servers "http://127.0.0.1:$ETCD_PORT" \
  --secure-port "$API_PORT" --bind-address 127.0.0.1 --cert-dir "$WORK/certs" \
  --service-account-issuer https://localhost --service-account-key-file "$WORK/sa.pub" \
  --service-account-signing-key-file "$WORK/sa.key" \
  --token-auth-file "$WORK/tokens.csv" --authorization-mode=RBAC \
  --service-cluster-ip-range 10.0.0.0/24 \
  --disable-admission-plugins=ServiceAccount >"$WORK/apiserver.log" 2>&1 &
PIDS+=($!)

KCTL=("$BIN/kubectl" --server "https://127.0.0.1:$API_PORT" --token validate-token --insecure-skip-tls-verify)
for _ in $(seq 1 60); do "${KCTL[@]}" get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
"${KCTL[@]}" get --raw /readyz >/dev/null || { echo "apiserver did not become ready"; tail -20 "$WORK/apiserver.log"; exit 1; }
echo "apiserver: $("${KCTL[@]}" version -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"

# --- CRDs ------------------------------------------------------------------------
find "$CRDS" -path '*/templates/*.yaml' -print0 | xargs -0 -n1 "${KCTL[@]}" apply -f >/dev/null
"${KCTL[@]}" wait --for=condition=Established crd --all --timeout=60s >/dev/null
echo "CRDs installed:"; "${KCTL[@]}" get crd -o name | sed 's/^/  /'
"${KCTL[@]}" create namespace kagent >/dev/null

# --- positive: must be accepted --------------------------------------------------
fail=0
echo; echo "== manifests/ and examples/ (must be accepted)"
for f in "$ROOT"/manifests/*.yaml "$ROOT"/examples/*.yaml; do
  if out="$(sed "s|\${WORKER_IMAGE}|$WORKER_IMAGE|g" "$f" | "${KCTL[@]}" apply --dry-run=server -f - 2>&1)"; then
    echo "$out" | sed "s|^|  ok   $(basename "$f"): |"
  else
    echo "  FAIL $(basename "$f")"; echo "$out" | sed 's/^/       /'; fail=1
  fi
done

# --- negative: must be rejected, proving the CEL rules ran -----------------------
echo; echo "== hack/negative/ (must be rejected)"
for f in "$ROOT"/hack/negative/*.yaml; do
  if out="$("${KCTL[@]}" apply --dry-run=server -f "$f" 2>&1)"; then
    echo "  FAIL $(basename "$f"): accepted, expected a rejection"; fail=1
  else
    echo "  ok   $(basename "$f"): rejected: $(echo "$out" | tr '\n' ' ' | sed 's/.*The //' | cut -c1-150)"
  fi
done

echo
if [ "$fail" -eq 0 ]; then echo "validate: PASS"; else echo "validate: FAIL"; exit 1; fi

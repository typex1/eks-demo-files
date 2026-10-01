#!/usr/bin/env bash
#
# fargate-connectivity-demo.sh
# -----------------------------
# Classroom demo: create an nginx pod in the "serverless" namespace (which the
# EKS Fargate profile schedules onto a Fargate node), then prove it is reachable
# over the network from a pod in a DIFFERENT namespace (default).
#
# What students should take away:
#   * Pods in the "serverless" namespace run on Fargate (serverless compute).
#   * EKS gives every pod a routable VPC IP via the AWS VPC CNI.
#   * With no NetworkPolicy in place, pods can talk across namespaces freely.
#
# Usage:
#   ./fargate-connectivity-demo.sh          # run the full demo
#   ./fargate-connectivity-demo.sh cleanup  # delete everything the demo created
#
# Requirements: kubectl (configured for the target cluster). The EKS Fargate
# profile matching the "serverless" namespace must already exist.

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SERVERLESS_NS="serverless"
CLIENT_NS="default"
SERVER_POD="serverless-nginx"
CLIENT_POD="netcheck-client"
SERVER_IMAGE="nginx:1.27"
CLIENT_IMAGE="nicolaka/netshoot:latest"
READY_TIMEOUT_FARGATE="180s"   # Fargate pods take longer (micro-VM provisioning)
READY_TIMEOUT_NORMAL="120s"

# ----------------------------------------------------------------------------
# Pretty output helpers (colors degrade gracefully if not a TTY)
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$(tput bold); RESET=$(tput sgr0)
  GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4); RED=$(tput setaf 1)
else
  BOLD=""; RESET=""; GREEN=""; YELLOW=""; BLUE=""; RED=""
fi

step()  { echo; echo "${BOLD}${BLUE}==> $*${RESET}"; }
info()  { echo "    ${YELLOW}$*${RESET}"; }
ok()    { echo "    ${GREEN}✓ $*${RESET}"; }
fail()  { echo "    ${RED}✗ $*${RESET}"; }

# Print a command, then run it (so students see exactly what happens).
run() {
  echo "    ${BOLD}\$ $*${RESET}"
  "$@"
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
cleanup() {
  step "Cleaning up demo resources"
  kubectl delete pod "$CLIENT_POD" -n "$CLIENT_NS" --ignore-not-found
  kubectl delete pod "$SERVER_POD" -n "$SERVERLESS_NS" --ignore-not-found
  kubectl delete namespace "$SERVERLESS_NS" --ignore-not-found
  ok "Cleanup complete."
}

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
preflight() {
  step "Checking prerequisites"
  if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl not found in PATH."; exit 1
  fi
  if ! kubectl get nodes >/dev/null 2>&1; then
    fail "Cannot reach the cluster. Is your kubeconfig set correctly?"; exit 1
  fi
  ok "kubectl is installed and the cluster is reachable."
}

# ----------------------------------------------------------------------------
# Main demo
# ----------------------------------------------------------------------------
main() {
  preflight

  # --- 1. Create the serverless (Fargate) namespace + pod -------------------
  step "1. Create the '$SERVERLESS_NS' namespace and an nginx pod (runs on Fargate)"
  info "The EKS Fargate profile matches this namespace, so the pod lands on Fargate."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $SERVERLESS_NS
  labels:
    name: $SERVERLESS_NS
---
apiVersion: v1
kind: Pod
metadata:
  name: $SERVER_POD
  namespace: $SERVERLESS_NS
  labels:
    app: $SERVER_POD
spec:
  containers:
  - name: nginx
    image: $SERVER_IMAGE
    ports:
    - containerPort: 80
EOF

  # --- 2. Create the client pod in a DIFFERENT namespace --------------------
  step "2. Create a client pod '$CLIENT_POD' in the '$CLIENT_NS' namespace"
  info "This pod lives in a different namespace and runs on a regular EC2 node."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $CLIENT_POD
  namespace: $CLIENT_NS
  labels:
    app: $CLIENT_POD
spec:
  containers:
  - name: netshoot
    image: $CLIENT_IMAGE
    command: ["sleep", "3600"]
EOF

  # --- 3. Wait for both pods to become Ready --------------------------------
  step "3. Wait for both pods to be Ready"
  info "Fargate pods start slower because a micro-VM is provisioned first."
  run kubectl wait --for=condition=Ready "pod/$SERVER_POD" -n "$SERVERLESS_NS" --timeout="$READY_TIMEOUT_FARGATE"
  run kubectl wait --for=condition=Ready "pod/$CLIENT_POD" -n "$CLIENT_NS" --timeout="$READY_TIMEOUT_NORMAL"
  ok "Both pods are Ready."

  # --- 4. Prove the server pod is on Fargate --------------------------------
  step "4. Confirm '$SERVER_POD' is scheduled on a Fargate node"
  run kubectl get pod "$SERVER_POD" -n "$SERVERLESS_NS" -o wide
  local node_name compute_type
  node_name=$(kubectl get pod "$SERVER_POD" -n "$SERVERLESS_NS" -o jsonpath='{.spec.nodeName}')
  compute_type=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/compute-type}')
  info "Node:         $node_name"
  info "Compute type: ${compute_type:-<none>}"
  if [[ "$compute_type" == "fargate" ]]; then
    ok "Confirmed: the pod is running on Fargate."
  else
    fail "Pod is NOT on Fargate (compute-type='${compute_type:-<none>}'). Check the Fargate profile."
  fi

  # --- 5. Grab the Fargate pod's IP -----------------------------------------
  step "5. Get the Fargate pod's IP address"
  local pod_ip
  pod_ip=$(kubectl get pod "$SERVER_POD" -n "$SERVERLESS_NS" -o jsonpath='{.status.podIP}')
  info "Target pod IP: ${BOLD}$pod_ip${RESET}"

  # --- 6. Test cross-namespace connectivity ---------------------------------
  step "6. Test connectivity from '$CLIENT_NS/$CLIENT_POD' -> '$SERVERLESS_NS/$SERVER_POD'"

  info "6a. ICMP reachability (ping):"
  if kubectl exec -n "$CLIENT_NS" "$CLIENT_POD" -- ping -c 3 -W 2 "$pod_ip"; then
    ok "Ping succeeded."
  else
    fail "Ping failed."
  fi

  echo
  info "6b. HTTP request on port 80 (curl):"
  local http_code
  http_code=$(kubectl exec -n "$CLIENT_NS" "$CLIENT_POD" -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$pod_ip" || true)
  info "HTTP status returned: ${BOLD}$http_code${RESET}"
  if [[ "$http_code" == "200" ]]; then
    ok "HTTP request succeeded — the Fargate pod is reachable across namespaces."
  else
    fail "HTTP request did not return 200 (got '$http_code')."
  fi

  # --- 7. Summary -----------------------------------------------------------
  step "Demo complete"
  info "Takeaways for students:"
  info "  * The nginx pod runs on Fargate (serverless), yet has a normal VPC pod IP."
  info "  * A pod in the '$CLIENT_NS' namespace reached it with no extra config."
  info "  * Namespaces alone do NOT isolate network traffic — use a NetworkPolicy for that."
  echo
  info "When finished, tear everything down with:"
  info "  ${BOLD}$0 cleanup${RESET}"
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------
case "${1:-run}" in
  cleanup) cleanup ;;
  run)     main ;;
  *)       echo "Usage: $0 [run|cleanup]"; exit 1 ;;
esac

#!/usr/bin/env bash
#
# 99-cleanup.sh — Remove everything created by this demo.
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME, e.g. export CLUSTER_NAME=my-cluster}"
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

NAMESPACE="pod-identity-demo"
SERVICE_ACCOUNT="demo-sa"
ROLE_NAME="eks-pod-identity-demo-role"
POLICY_NAME="eks-pod-identity-demo-policy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Deleting Kubernetes resources..."
kubectl delete -f "${SCRIPT_DIR}/02-k8s-resources.yaml" --ignore-not-found

echo "==> Deleting Pod Identity association(s)..."
for ID in $(aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${NAMESPACE}" \
    --region "${AWS_REGION}" \
    --query "associations[?serviceAccount=='${SERVICE_ACCOUNT}'].associationId" \
    --output text 2>/dev/null || true); do
  [[ -z "${ID}" || "${ID}" == "None" ]] && continue
  echo "    Deleting association ${ID}"
  aws eks delete-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --association-id "${ID}" \
    --region "${AWS_REGION}"
done

echo "==> Removing IAM role policy and role..."
aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${POLICY_NAME}" 2>/dev/null || true
aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true

echo "==> (Optional) The eks-pod-identity-agent add-on is left installed."
echo "    To remove it too, run:"
echo "      aws eks delete-addon --cluster-name ${CLUSTER_NAME} \\"
echo "        --addon-name eks-pod-identity-agent --region ${AWS_REGION}"

echo "==> Cleanup complete."

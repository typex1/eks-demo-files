#!/usr/bin/env bash
#
# 01-setup.sh — Create the AWS-side resources for the EKS Pod Identity demo.
#
# Steps (mirroring the article "How to Implement EKS Pod Identity"):
#   1. Install the eks-pod-identity-agent EKS add-on.
#   2. Create an IAM role trusting pods.eks.amazonaws.com (reusable trust policy).
#   3. Attach a minimal permissions policy to the role.
#   4. Map the association: IAM role  <->  Namespace + ServiceAccount.
#
set -euo pipefail

# ---- Config (override via environment) --------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME, e.g. export CLUSTER_NAME=my-cluster}"
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

NAMESPACE="pod-identity-demo"
SERVICE_ACCOUNT="demo-sa"
ROLE_NAME="eks-pod-identity-demo-role"
POLICY_NAME="eks-pod-identity-demo-policy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Cluster:        ${CLUSTER_NAME}"
echo "==> Region:         ${AWS_REGION}"
echo "==> Account:        ${ACCOUNT_ID}"
echo "==> Namespace/SA:   ${NAMESPACE} / ${SERVICE_ACCOUNT}"
echo "==> IAM role:       ${ROLE_NAME}"
echo

# ---- 1. Install the eks-pod-identity-agent add-on ---------------------------
echo "==> [1/4] Installing eks-pod-identity-agent add-on (idempotent)..."
if aws eks describe-addon \
      --cluster-name "${CLUSTER_NAME}" \
      --addon-name eks-pod-identity-agent \
      --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "    Add-on already present. Skipping."
else
  aws eks create-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name eks-pod-identity-agent \
    --region "${AWS_REGION}"
  echo "    Waiting for add-on to become ACTIVE..."
  aws eks wait addon-active \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name eks-pod-identity-agent \
    --region "${AWS_REGION}"
fi

# ---- 2. Create the IAM role (reusable trust policy) -------------------------
echo "==> [2/4] Creating IAM role ${ROLE_NAME} (idempotent)..."
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    Role already exists. Skipping create."
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${SCRIPT_DIR}/trust-policy.json" \
    --description "Demo role assumed via EKS Pod Identity (pods.eks.amazonaws.com)"
fi

# ---- 3. Attach a minimal permissions policy --------------------------------
echo "==> [3/4] Attaching inline permissions policy ${POLICY_NAME}..."
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${SCRIPT_DIR}/permissions-policy.json"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# ---- 4. Create the Pod Identity association --------------------------------
echo "==> [4/4] Creating Pod Identity association (idempotent)..."
EXISTING_ID=$(aws eks list-pod-identity-associations \
  --cluster-name "${CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" \
  --region "${AWS_REGION}" \
  --query "associations[?serviceAccount=='${SERVICE_ACCOUNT}'].associationId" \
  --output text 2>/dev/null || true)

if [[ -n "${EXISTING_ID}" && "${EXISTING_ID}" != "None" ]]; then
  echo "    Association already exists (${EXISTING_ID}). Skipping."
else
  aws eks create-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${NAMESPACE}" \
    --service-account "${SERVICE_ACCOUNT}" \
    --role-arn "${ROLE_ARN}" \
    --region "${AWS_REGION}"
fi

echo
echo "==> Setup complete."
echo "    Role ARN: ${ROLE_ARN}"
echo "    Next:     kubectl apply -f 02-k8s-resources.yaml"
echo "    Then:     ./03-verify.sh"

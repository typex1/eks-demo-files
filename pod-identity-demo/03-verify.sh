#!/usr/bin/env bash
#
# 03-verify.sh — Prove that the pod received AWS credentials via EKS Pod Identity.
#
# This exec's into the running pod and:
#   1. Shows the Pod Identity env vars the agent injected (no static keys!).
#   2. Calls `aws sts get-caller-identity` to reveal the assumed-role session.
#   3. Exercises the granted S3 permission (s3:ListAllMyBuckets).
#
set -euo pipefail

NAMESPACE="pod-identity-demo"
POD="aws-caller"

echo "==> Waiting for pod ${POD} to be Ready..."
kubectl wait --for=condition=Ready "pod/${POD}" -n "${NAMESPACE}" --timeout=120s

echo
echo "==> [1/3] Pod Identity environment variables injected by the agent:"
echo "    (These replace static credentials and IRSA token files.)"
kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
  'env | grep -E "AWS_CONTAINER_CREDENTIALS_FULL_URI|AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE|AWS_DEFAULT_REGION" || true'

echo
echo "==> [2/3] Who am I? (aws sts get-caller-identity from INSIDE the pod)"
echo "    Expect an 'assumed-role/eks-pod-identity-demo-role/...' ARN."
kubectl exec -n "${NAMESPACE}" "${POD}" -- aws sts get-caller-identity

echo
echo "==> [3/3] Exercising granted permission (aws s3 ls):"
kubectl exec -n "${NAMESPACE}" "${POD}" -- aws s3 ls || {
  echo "    (If this errors with AccessDenied, the association or policy is not active yet.)"
}

echo
echo "==> Verification complete."
echo "    Key takeaways:"
echo "      - No static credentials, no IRSA annotation, no OIDC provider."
echo "      - Credentials delivered natively by eks-pod-identity-agent."
echo "      - The AssumeRole call carries automatic session tags:"
echo "        eks-cluster-name / kubernetes-namespace / kubernetes-service-account"
echo "        (visible in CloudTrail for the sts:AssumeRole event)."

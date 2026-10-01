# Demo: EKS Pod Identity

A hands-on demo that implements **Amazon EKS Pod Identity** end-to-end and lets students
*prove* that a pod receives AWS credentials without any OIDC provider, IRSA annotations, or
hardcoded keys.

> Companion to the article **IRSA vs. EKS Pod Identity**. Where that article explains the
> *theory*, this demo makes it *runnable*.

---

## What this demo shows

1. The `eks-pod-identity-agent` add-on delivers credentials natively (no OIDC provider).
2. A single IAM role with a **reusable** trust policy (`pods.eks.amazonaws.com`) — the same
   role could be reused on any cluster.
3. The association between the IAM role and a Kubernetes **Namespace + ServiceAccount** is
   defined at the **EKS API level**, not via ServiceAccount annotations (the IRSA way).
4. A running pod calls AWS STS and S3 using **only** the auto-injected credentials, and we
   observe the **automatic session tags** (`eks-cluster-name`, `kubernetes-namespace`,
   `kubernetes-service-account`) in the caller identity.

---

## Prerequisites

- An EKS cluster (Kubernetes 1.24+) and `kubectl` pointed at it.
- AWS CLI v2 configured with permissions to manage IAM, EKS add-ons, and Pod Identity
  associations.
- `jq` (used by the verification script for readable output).
- Set your cluster name once:

  ```bash
  export CLUSTER_NAME=my-cluster
  export AWS_REGION=eu-central-1
  export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  ```

> **Note on Fargate:** Pod Identity relies on the `eks-pod-identity-agent` DaemonSet, which
> does **not** run on Fargate. Run this demo on an **EC2-backed** node group. (See the
> article's "When Should You Still Use IRSA?" section.)

---

## Files

| File | Purpose |
| --- | --- |
| `01-setup.sh`            | Installs the add-on, creates the IAM role, and creates the Pod Identity association. |
| `trust-policy.json`      | The reusable trust policy (`pods.eks.amazonaws.com`). |
| `permissions-policy.json`| A minimal read-only S3 policy for the demo app to exercise. |
| `02-k8s-resources.yaml`  | Namespace, ServiceAccount, and a demo pod that calls AWS. |
| `03-verify.sh`           | Proves the pod has credentials and shows the automatic session tags. |
| `99-cleanup.sh`          | Tears everything down. |

---

## Run it

```bash
cd pod-identity-demo

# 1. Create the AWS-side resources (add-on, IAM role, association)
./01-setup.sh

# 2. Deploy the Kubernetes resources
kubectl apply -f 02-k8s-resources.yaml

# 3. Prove the pod has an identity (and see the automatic session tags)
./03-verify.sh

# 4. Clean up
./99-cleanup.sh
```

---

## What success looks like

`03-verify.sh` runs `aws sts get-caller-identity` **from inside the pod**. The returned ARN
is an **assumed-role** session, e.g.:

```
arn:aws:sts::123456789012:assumed-role/eks-pod-identity-demo-role/eks-my-cluster-...
```

Notice:

- The pod never had static credentials or an IRSA annotation.
- The credentials were injected by the agent via the mounted token and
  `AWS_CONTAINER_CREDENTIALS_FULL_URI` environment variable.
- CloudTrail for the `AssumeRole` call carries the session tags `eks-cluster-name`,
  `kubernetes-namespace`, and `kubernetes-service-account` — set **automatically**.

---

## IRSA vs. Pod Identity — where it shows up in this demo

| Concept | IRSA would require | This demo (Pod Identity) |
| --- | --- | --- |
| OIDC provider | `eksctl utils associate-iam-oidc-provider ...` | **Nothing** |
| Trust policy | References cluster OIDC ARN + SA (per cluster) | Generic `pods.eks.amazonaws.com` (reusable) |
| SA → role mapping | `eks.amazonaws.com/role-arn` annotation on the SA | `aws eks create-pod-identity-association` (EKS API) |
| Session tags | Manual | Automatic |

Note that `02-k8s-resources.yaml` has **no** `eks.amazonaws.com/role-arn` annotation on the
ServiceAccount — that is the IRSA mechanism, and it is deliberately absent here.

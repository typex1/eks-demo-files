# EKS Q&A — Scheduling Conflicts

## Question

A pod needs to be scheduled, and its **node affinity** is enforcing it to be scheduled on a
specific EC2 instance type. But it happens that the **namespace** the pod is in has a matching
**Fargate profile**, telling that the pod needs to run on Fargate.

**So where will the pod finally be placed?**

---

## Short Answer

> **The pod will NOT be scheduled at all. It stays `Pending`.**

It is neither forced onto EC2 nor onto Fargate — the two requirements contradict each other,
so no node can satisfy them.

---

## Why? Step by Step

### 1. Fargate profile selection happens *first*, at admission time

On EKS, a **Fargate profile** matches pods by **namespace** (and optionally by labels/selectors).
This decision is made *before* the scheduler ever runs.

When a pod is created in a namespace that matches a Fargate profile, the EKS Fargate
**mutating admission webhook** intercepts the pod and does two things:

1. Sets the pod's `schedulerName` to `fargate-scheduler` (instead of `default-scheduler`).
2. Injects a node affinity that binds the pod to a Fargate virtual node, labeled:
   ```
   eks.amazonaws.com/compute-type: fargate
   ```

> **Key point:** The "this pod belongs to Fargate" decision is based purely on the
> **namespace match** — not on a scheduler-time comparison against your affinity rules.

### 2. Your node affinity is *not* removed — it is *added to*

Your pod already carries a node affinity like:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - m5.large        # a specific EC2 instance type
```

The Fargate webhook does **not** delete this. It adds its own affinity on top.

Multiple `requiredDuringSchedulingIgnoredDuringExecution` requirements are **ANDed together**.

### 3. The contradiction

The pod now effectively requires **both** of the following at the same time:

| Requirement (injected by Fargate) | Requirement (your affinity) |
| --------------------------------- | --------------------------- |
| `compute-type = fargate`          | `instance-type = m5.large`  |

No single node can satisfy both:

- A **Fargate** virtual node has `compute-type: fargate`, but has **no** EC2 `instance-type`
  label (it is not an EC2 instance).
- An **EC2** node has the `instance-type` label, but does **not** have `compute-type: fargate`.

On top of that, the pod is now owned by `fargate-scheduler`, so:

- The **default scheduler** ignores it (not its pod).
- The **Fargate scheduler** can only place it on Fargate — which your EC2 affinity forbids.

### 4. Result

```
$ kubectl get pod my-pod
NAME      READY   STATUS    RESTARTS   AGE
my-pod    0/1     Pending   0          3m
```

You will see a `FailedScheduling` event, and **no Fargate capacity gets provisioned**.
The pod stays `Pending` indefinitely.

---

## Key Takeaways

- **Fargate matching is by namespace** (and optional labels), decided at **admission time** —
  it is *not* a scheduler tie-break against your affinity.
- **Your node affinity is not overridden.** It is combined (ANDed) with the injected Fargate
  affinity, producing an **unsatisfiable** requirement.
- The conflict does not "pick a winner" — it makes the pod **unschedulable**.

---

## How to Avoid This Conflict

Pick **one** compute type per namespace, then choose one of these fixes:

1. **Don't add EC2-targeting node affinity** to pods in a Fargate-matched namespace.
2. **Use a different namespace** (or labels) so the pod does *not* match the Fargate profile —
   this lets the default scheduler honor your EC2 affinity.
3. **Adjust the Fargate profile's selectors** so this pod no longer matches, if you genuinely
   want it on EC2.

---

## Quick Reference

```
Fargate profile match (by namespace/labels)
        │
        ▼
Admission webhook rewrites the pod:
   • schedulerName        → fargate-scheduler
   • + nodeAffinity        compute-type=fargate
        │
        ▼
Pod now requires:  compute-type=fargate  AND  instance-type=<EC2 type>
        │
        ▼
   No node matches both  ──►  Pod stays Pending
```

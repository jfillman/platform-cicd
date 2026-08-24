# Architecture Decision Records

One file per load-bearing decision: what it is, why it was made this way, and what it
costs. Written after the fact from the real design/implementation history - see
[../../archive/](../../archive/) for the original, unabridged design record these were
distilled from.

| ADR | Decision |
|---|---|
| [0001](0001-tekton-pipelines-as-code.md) | Tekton + Pipelines-as-Code, vanilla Kubernetes |
| [0002](0002-cdevents-broker-tokenreview.md) | CDEvents broker with TokenReview auth for inter-stage chaining |
| [0003](0003-governance-stubs.md) | Governance gates as explicit, structurally-loud extension points |
| [0004](0004-gitops-only-release.md) | GitOps-only release promotion |
| [0005](0005-multicluster-per-cluster-argocd.md) | Per-cluster ArgoCD instances, event-driven outcome reporting |
| [0006](0006-cluster-agnostic-bootstrap.md) | Cluster-agnostic bootstrap, no cluster state in the app repo |
| [0007](0007-testkube-shared-namespace.md) | Testkube CE in one shared namespace, not one per tenant |
| [0008](0008-kyverno-testkube-secret-policy.md) | Kyverno ValidatingPolicy closes the Testkube shared-secret gap |

New decisions get a new numbered file here, not a paragraph buried in an unrelated doc.

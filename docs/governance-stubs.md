# Governance stubs

The old platform had named quality gates - QA, gatekeeper/OPA, image-scan-check,
SAST-check, ArgoCD-health-check - that were literal `exit 0` one-liners, reported to
developers with the same visual confidence as the gates that actually ran real checks.
Roughly half the platform's "compliance story" was theater, and nothing in the system
told you which half.

This platform's answer, agreed as an explicit scope decision (not an oversight): ship
the **shape** of governance now - `sast`, `imageScan`, `policyCheck`, `sbom` toggles in
`cicd.yaml`, wired into the Pipeline DAG, visible in the dashboard - without pretending
any of them do real enforcement yet. Real implementations are Phase 3.

## How a stub stays honestly a stub

Every governance Task in the catalog (`catalog/tasks/governance-gate-stub.yaml`) calls
`catalog/stepactions/governance-stub.yaml`, which:

1. Logs, loudly, to the step's own output: `no real check implemented yet`.
2. Emits an OTel span event `governance.stub` carrying `governance.stub=true` and
   `governance.gate=<name>` - a structural, machine-readable fact attached to the trace
   itself, not a comment someone can miss.
3. Sets its Task result to the literal string `"stub"` - never `"passed"` or `"failed"`,
   which would imply a real judgment was made.

[`observability/grafana/dashboards/pipeline-detail.json`](../observability/grafana/dashboards/pipeline-detail.json)'s
"Governance gates in this run" panel renders any `governance.stub=true` row with a
distinct grey background and the label "STUB - not a real check", specifically so a stub
can never be visually confused with a real pass/fail result on the dashboard a developer
or a leader actually looks at.

## Landing a real implementation

When a real check (SAST, image scanning, Kyverno/OPA policy check, SBOM generation)
lands in Phase 3, the fix is: delete the `governance-stub` call from that one Task, add
the real logic, keep the Task's name/params/results contract the same. Nothing about the
Pipeline shape, the `cicd.yaml` schema, or the dashboard panel needs to change - the
stub/real distinction was designed to be a one-Task-at-a-time swap, not a platform
migration.

# ADR-0008: Kyverno ValidatingPolicy closes the Testkube shared-secret gap

## Context

ADR-0007 documents why Testkube CE runs every onboarded Application's TestWorkflows in
one shared `testkube` namespace, with per-Application secrets reaching a workflow via a
pre-seeded placeholder Secret (`<appName>-app-secrets`) that a Tekton Task
re-materializes immediately before each run and blanks again immediately after.

That design has a real gap, caught in review, not by an attacker: Kubernetes RBAC gates
who may read/write a Secret *object* via the API, but not which Secret *names* a Pod
spec is allowed to mount. The resourceNames-restricted RBAC in `rbac-and-secret.yaml`
stops a tenant's `pipeline-runner` from *creating or tampering with* another tenant's
placeholder Secret - it does nothing to stop a tenant from simply writing
`secretKeyRef.name: otherApp-app-secrets` into their own `platform/<name>.yaml`
(self-service, no operator review) and reading whatever happens to be in it. The
existing "materialize, blank" cycle only narrows *when* that data is exposed; it
doesn't close *who* can read it.

Two paths were considered to close this for real:

1. **Testkube's own `config.<name>.sensitive: true` mechanism** - the product's
   documented answer to exactly this problem (auto-materializes a per-execution,
   uniquely-named, non-guessable Secret instead of a durable one). Tried live,
   2026-08-24, through the correct trigger path (the REST API, not the raw
   `TestWorkflowExecution` CR-create path this platform otherwise uses): the execution
   aborted with `configParams: {emptyValue: true}` and no secret was ever created. Same
   family of gap as ADR-0007's `executionNamespaces` finding - real in the schema,
   not delivered in this CE build.
2. **An admission-time policy** - enforce the naming rule as a hard gate instead of a
   convention, at the one point in the request lifecycle where the real tenant identity
   is still visible.

## Decision

Kyverno (CE, `ValidatingPolicy` - the new CEL-native CRD, GA as of Kyverno 1.17, chosen
over the now-deprecating JMESPath `ClusterPolicy` shape since this is a fresh install
with no migration debt to inherit) enforces: a TestWorkflow's
`spec.container.env[].valueFrom.secretKeyRef.name` (and the same field under
`spec.steps[].container.env[]`) may only equal the *requesting* tenant's own
`<appName>-app-secrets`, for any `CREATE`/`UPDATE` whose caller is a tenant
`pipeline-runner` ServiceAccount.

The enforcement point matters: this runs at TestWorkflow apply time, where
`request.userInfo.username` is still `system:serviceaccount:<type>-<appName>-cicd:
pipeline-runner` - a real, unforgeable identity. It deliberately does *not* try to
enforce this later, when Testkube's own controller creates the execution Job - by then
the creating identity is uniformly `testkube-api-server`'s own ServiceAccount for every
tenant alike, and that information is gone. `appName` is derived from the caller's own
namespace via Kyverno's built-in `parseServiceAccount()` CEL function (not manual
string-splitting - `<appName>` itself may contain hyphens, and stripping the fixed
`app-`/`infra-` prefix and `-cicd` suffix from the *namespace* is unambiguous in a way
splitting on `:` or `-` generically would not be).

Non-ServiceAccount callers (human/OIDC kubeconfig users) and Testkube's own
ServiceAccounts are excluded - the former already implies cluster-access trust, the
latter is the controller's own reconcile traffic (status/finalizer updates), not
tenant-submitted specs.

Live-verified 2026-08-24 against the real cluster, with real tenant identities via
`kubectl --as`:
- `checkout-api`'s own `pipeline-runner` referencing its own `checkout-api-app-secrets`:
  **allowed**, both at `spec.container.env` and `spec.steps[].container.env`.
- The same identity referencing a different Application's secret name at either
  location: **denied outright** by the admission webhook, exact policy message
  returned.
- The real, already-in-production `checkout-api/platform/integration.yaml` (with its
  `__APP_SECRETS_NAME__` placeholder substituted, exactly as `run-testworkflow.yaml`
  does it live): still applies cleanly - the policy doesn't break the legitimate path.

One real, live-found operational gap along the way: Kyverno's own controllers ship RBAC
for built-in Kubernetes kinds only. A policy matching a CRD needs a supplemental
`ClusterRole` aggregated via the `rbac.kyverno.io/aggregate-to-{admission,background,
reports}-controller` labels (confirmed against this cluster's own installed
`ClusterRole.aggregationRule` selectors, not assumed from docs) - without it, Kyverno
itself reports "Policy is not ready for reporting, missing permissions: get/list/watch
testworkflows.testkube.io."

## Consequences

- Closes the actual read-access gap ADR-0007 could only narrow: a tenant can no longer
  reference another tenant's placeholder Secret, full stop, regardless of timing.
- Scope, stated plainly rather than assumed: only `spec.container.env` and
  `spec.steps[].container.env` are checked - the two locations this platform's own
  authoring convention documents. TestWorkflow's schema allows `secretKeyRef` in other
  nested locations too (`services[]`, `setup`, `after`) that this first pass does not
  cover. Known gap, not silently assumed safe - extend the policy's `validations` list
  if those locations come into real use.
- Kyverno is now real, load-bearing cluster infrastructure, not an empty placeholder -
  `30-policy/` in both `gitops-cluster-dev` and `gitops-cluster-template`, gated by
  `components.policy` (wired into `customize-cluster.sh` for the first time this same
  pass - the toggle existed in `cluster.yaml.example` before but was never connected to
  anything).
- A future upgrade to Testkube Pro/Enterprise removing the need for a shared namespace
  entirely (ADR-0007's own reversibility note) would make this policy moot, not wrong -
  it would simply have nothing left to match.

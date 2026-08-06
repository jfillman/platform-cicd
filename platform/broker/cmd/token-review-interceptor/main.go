// platform/broker/cmd/token-review-interceptor/main.go
//
// Implements the Tekton Triggers ClusterInterceptor webhook contract. Registered as a
// ClusterInterceptor named "cdevents-broker-auth" (see
// ../../manifests/cluster-interceptor.yaml) and referenced from every Application's
// Trigger CRs (see charts/platform-cicd-app/templates/triggers/*.yaml).
//
// Purpose: authenticate callers of the shared CDEvents broker using each caller's own
// cluster-issued, audience-bound projected ServiceAccount token (verified via the
// Kubernetes TokenReview API) instead of a platform-minted credential - see
// docs/chaining.md for why this replaces the old platform's JWT-minting-server
// entirely. On success this sets extensions.app_namespace to the calling SA's
// namespace; every Application's own Trigger CEL filter then checks that against the
// CDEvent's declared source namespace. That check, not network topology, is the real
// app-isolation boundary on this shared broker - see docs/chaining.md.
//
// This service also mints scoped GitHub App installation tokens for the release stage's
// GitOps PR flow (see github_app.go and handleGitHubInstallationToken below) - a scope
// extension of this same trusted, TokenReview-authenticated component rather than a new
// service, since the alternative (copying the App's private key into every Application
// namespace) would let one compromised Application's Task mint tokens for every other
// Application's repos. See docs/release.md.
//
// NOTE: the request/response JSON shape below mirrors the documented Tekton Triggers
// ClusterInterceptor webhook contract (InterceptorRequest/InterceptorResponse). Re-
// verify field names against whichever Triggers version is pinned in Phase 0 before
// trusting this in a real cluster - see the plan's build-sequence Phase 0 item.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"

	authenticationv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// The PaC Repository CRD - read-only, used only to check "does this Application actually
// own an app that resolves to the gitops repo it's asking a token for" (see
// handleGitHubInstallationToken). Never written to.
var repositoryGVR = schema.GroupVersionResource{Group: "pipelinesascode.tekton.dev", Version: "v1alpha1", Resource: "repositories"}

type interceptorRequest struct {
	Body              string                 `json:"body"`
	Header            map[string][]string    `json:"header"`
	Extensions        map[string]interface{} `json:"extensions"`
	InterceptorParams map[string]interface{} `json:"interceptor_params"`
}

type status struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type interceptorResponse struct {
	Extensions map[string]interface{} `json:"extensions,omitempty"`
	Continue   bool                   `json:"continue"`
	Status     status                 `json:"status"`
}

// gRPC-style codes used in the Status.Code field of the interceptor contract.
const (
	codeOK              = 0
	codeInvalidArgument = 3
	codeUnauthenticated = 16
)

const defaultAudience = "cdevents-broker"

// Plain HTTP, not HTTPS, deliberately - not an oversight. This service was originally
// TLS-terminated with a cert-manager-issued self-signed-CA certificate, matching how
// Tekton's own built-in ClusterInterceptors (cel, github, ...) are configured via
// spec.clientConfig.caBundle. In practice the EventListener sink rejected that cert on
// every call ("x509: certificate signed by unknown authority") no matter what was tried
// live against a real cluster: confirming the CA genuinely issued the serving cert,
// restarting the sink to rule out a stale informer cache, deleting and recreating the
// ClusterInterceptor with caBundle set at creation instead of patched in afterward, and
// attempting to add the CA to the sink pod's own trust store - blocked outright by the
// EventListener CRD's admission webhook ("must not set the field(s): ...volumes,
// ...volumeMounts, ...env[].value"), and a direct patch of the underlying Deployment
// was silently reverted by the EventListener reconciler on the next resync. Whatever
// the built-in interceptors rely on to make caBundle work is not something a custom
// ClusterInterceptor could reach in the time available to debug it live.
//
// This is not a silent downgrade of the security model: per docs/chaining.md, the real
// trust boundary here was always TokenReview-verified caller identity, not transport
// TLS - this call never leaves the cluster, and NetworkPolicy enforcement on
// kind-observe is already a documented, accepted gap for the same reason (see
// docs/bootstrap.md). Revisit if this needs to run somewhere the caBundle mechanism
// can be made to work, or if a later Triggers version fixes whatever this hit.
func main() {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("loading in-cluster config: %v", err)
	}
	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("building clientset: %v", err)
	}
	dynClient, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("building dynamic client: %v", err)
	}

	// Loaded once at startup, not lazily per-request: fail fast and loudly if the
	// github-app-creds volume isn't mounted correctly, rather than only discovering it
	// on the first release PR attempt.
	appCreds, err := loadGitHubAppCreds()
	if err != nil {
		log.Fatalf("loading GitHub App credentials: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handle(clientset))
	mux.HandleFunc("/github-installation-token", handleGitHubInstallationToken(clientset, dynClient, appCreds))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	log.Println("cdevents-broker-auth interceptor listening on :8080 (plain HTTP - see comment above)")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

func handle(clientset kubernetes.Interface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req interceptorRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeInvalidArgument, Message: "invalid request body: " + err.Error()}})
			return
		}

		audience, _ := req.InterceptorParams["audience"].(string)
		if audience == "" {
			audience = defaultAudience
		}

		token := bearerToken(firstHeader(req.Header, "Authorization"))
		if token == "" {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeUnauthenticated, Message: "missing or malformed Authorization: Bearer <token> header"}})
			return
		}

		appNamespace, authErr := verifyCallerAppNamespace(clientset, token, audience)
		if authErr != "" {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeUnauthenticated, Message: authErr}})
			return
		}

		writeJSON(w, interceptorResponse{
			Continue:   true,
			Extensions: map[string]interface{}{"app_namespace": appNamespace},
			Status:     status{Code: codeOK},
		})
	}
}

// verifyCallerAppNamespace runs the same TokenReview check the CDEvents broker path
// uses, shared with handleGitHubInstallationToken below - one trust primitive, two
// callers. Returns the caller's namespace, or an empty namespace + a human-readable
// error message on any failure.
func verifyCallerAppNamespace(clientset kubernetes.Interface, token, audience string) (namespace string, errMsg string) {
	review := &authenticationv1.TokenReview{
		Spec: authenticationv1.TokenReviewSpec{
			Token:     token,
			Audiences: []string{audience},
		},
	}
	result, err := clientset.AuthenticationV1().TokenReviews().Create(context.Background(), review, metav1.CreateOptions{})
	if err != nil {
		return "", "TokenReview call failed: " + err.Error()
	}
	if !result.Status.Authenticated {
		return "", "token not authenticated: " + result.Status.Error
	}

	// SA-token usernames are "system:serviceaccount:<namespace>:<name>".
	parts := strings.Split(result.Status.User.Username, ":")
	if len(parts) != 4 || parts[0] != "system" || parts[1] != "serviceaccount" {
		return "", "caller is not a ServiceAccount identity"
	}
	return parts[2], ""
}

func bearerToken(authHeader string) string {
	token := strings.TrimPrefix(authHeader, "Bearer ")
	if token == authHeader {
		return "" // no "Bearer " prefix present
	}
	return token
}

type githubInstallationTokenRequest struct {
	Owner string `json:"owner"`
	Repo  string `json:"repo"`
}

type githubInstallationTokenResponse struct {
	Token     string `json:"token,omitempty"`
	ExpiresAt string `json:"expiresAt,omitempty"`
	Error     string `json:"error,omitempty"`
}

// handleGitHubInstallationToken mints a GitHub App installation token scoped to exactly
// one repo, for a caller whose own Application namespace genuinely owns that repo -
// either directly (its own app repo, e.g. for the ephemeral-envs ApplicationSet's
// PR-listing token, see docs/ephemeral-environments.md) or via the platform's
// gitops-<app-name> convention (see docs/release.md). It's not enough that the caller
// presents a valid ServiceAccount token (that only proves *which* Application is
// asking) - the Application also has to actually have a PaC Repository CR whose name
// matches the requested repo. Deliberately narrow (list, not any write verb) RBAC on
// repositories.pipelinesascode.tekton.dev is all this needs from its own
// ServiceAccount.
func handleGitHubInstallationToken(clientset kubernetes.Interface, dynClient dynamic.Interface, appCreds *githubAppCreds) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		token := bearerToken(r.Header.Get("Authorization"))
		if token == "" {
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: "missing or malformed Authorization: Bearer <token> header"})
			return
		}
		appNamespace, authErr := verifyCallerAppNamespace(clientset, token, "github-installation-token")
		if authErr != "" {
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: authErr})
			return
		}

		var body githubInstallationTokenRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Owner == "" || body.Repo == "" {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: "request body must be {\"owner\":..., \"repo\":...}"})
			return
		}

		if err := verifyAppOwnsRepo(dynClient, appNamespace, body.Repo); err != nil {
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: err.Error()})
			return
		}

		appJWT, err := appCreds.signAppJWT()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: "signing App JWT: " + err.Error()})
			return
		}
		installationID, err := installationIDForRepo(appJWT, body.Owner, body.Repo)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: err.Error()})
			return
		}
		instToken, expiresAt, err := mintInstallationToken(appJWT, installationID, body.Repo)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Error: err.Error()})
			return
		}

		_ = json.NewEncoder(w).Encode(githubInstallationTokenResponse{Token: instToken, ExpiresAt: expiresAt})
	}
}

// verifyAppOwnsRepo lists PaC Repository CRs in the caller's own namespace (never
// cross-namespace - the caller can only ever prove it, not other Applications') and
// checks whether any of them, by name, match the requested repo either directly (the
// app's own repo - needed by the ApplicationSet's pullRequest-generator token, which
// lists PRs on the app repo itself, see docs/ephemeral-environments.md) or via this
// platform's gitops-<app-name> convention (see catalog/tasks/open-release-pr.yaml,
// docs/release.md). Deliberately does NOT trust the requested "owner" as part of this
// check - the app name -> gitops repo mapping is owner-agnostic by design (an
// Application's app-repo org and its gitops-repo org don't have to match, same lesson
// learned the hard way earlier in this platform's build - see docs/chaining.md).
func verifyAppOwnsRepo(dynClient dynamic.Interface, appNamespace, requestedRepo string) error {
	list, err := dynClient.Resource(repositoryGVR).Namespace(appNamespace).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("listing Repository CRs in %s: %w", appNamespace, err)
	}
	for _, item := range list.Items {
		appName, _, _ := unstructured.NestedString(item.Object, "metadata", "name")
		if appName != "" && (appName == requestedRepo || "gitops-"+appName == requestedRepo) {
			return nil
		}
	}
	return fmt.Errorf("app namespace %q has no Repository CR that maps to repo %q", appNamespace, requestedRepo)
}

func firstHeader(h map[string][]string, key string) string {
	for k, v := range h {
		if strings.EqualFold(k, key) && len(v) > 0 {
			return v[0]
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, resp interceptorResponse) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

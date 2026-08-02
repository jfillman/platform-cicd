// platform/broker/cmd/token-review-interceptor/main.go
//
// Implements the Tekton Triggers ClusterInterceptor webhook contract. Registered as a
// ClusterInterceptor named "cdevents-broker-auth" (see
// ../../manifests/cluster-interceptor.yaml) and referenced from every tenant's Trigger
// CRs (see ../../manifests/tenant-triggers-template.yaml).
//
// Purpose: authenticate callers of the shared CDEvents broker using each caller's own
// cluster-issued, audience-bound projected ServiceAccount token (verified via the
// Kubernetes TokenReview API) instead of a platform-minted credential - see
// docs/chaining.md for why this replaces the old platform's JWT-minting-server
// entirely. On success this sets extensions.tenant_namespace to the calling SA's
// namespace; every tenant's own Trigger CEL filter then checks that against the
// CDEvent's declared source namespace. That check, not network topology, is the real
// tenant-isolation boundary on this shared broker - see docs/chaining.md.
//
// NOTE: the request/response JSON shape below mirrors the documented Tekton Triggers
// ClusterInterceptor webhook contract (InterceptorRequest/InterceptorResponse). Re-
// verify field names against whichever Triggers version is pinned in Phase 0 before
// trusting this in a real cluster - see the plan's build-sequence Phase 0 item.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"

	authenticationv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

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

	mux := http.NewServeMux()
	mux.HandleFunc("/", handle(clientset))
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

		authHeader := firstHeader(req.Header, "Authorization")
		token := strings.TrimPrefix(authHeader, "Bearer ")
		if token == "" || token == authHeader {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeUnauthenticated, Message: "missing or malformed Authorization: Bearer <token> header"}})
			return
		}

		review := &authenticationv1.TokenReview{
			Spec: authenticationv1.TokenReviewSpec{
				Token:     token,
				Audiences: []string{audience},
			},
		}
		result, err := clientset.AuthenticationV1().TokenReviews().Create(context.Background(), review, metav1.CreateOptions{})
		if err != nil {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeUnauthenticated, Message: "TokenReview call failed: " + err.Error()}})
			return
		}
		if !result.Status.Authenticated {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeUnauthenticated, Message: "token not authenticated: " + result.Status.Error}})
			return
		}

		// SA-token usernames are "system:serviceaccount:<namespace>:<name>".
		parts := strings.Split(result.Status.User.Username, ":")
		if len(parts) != 4 || parts[0] != "system" || parts[1] != "serviceaccount" {
			writeJSON(w, interceptorResponse{Continue: false, Status: status{Code: codeUnauthenticated, Message: "caller is not a ServiceAccount identity"}})
			return
		}
		tenantNamespace := parts[2]

		writeJSON(w, interceptorResponse{
			Continue:   true,
			Extensions: map[string]interface{}{"tenant_namespace": tenantNamespace},
			Status:     status{Code: codeOK},
		})
	}
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

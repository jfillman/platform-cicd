// platform/broker/cmd/argocd-outcome-relay/main.go
//
// Closes the loop on the release stage (Phase 3 item 4, docs/multi-cluster.md): an
// upper-env cluster's own outcome-reporting hook Jobs (see catalog/lib/
// argocd-outcome-hook.sh, PostSync/SyncFail ArgoCD sync hooks) POST here once a
// release genuinely completes, and this service reshapes that into a real CDEvent and
// forwards it into the existing, UNMODIFIED broker
// (charts/platform-cicd-control-plane/templates/broker/eventlistener.yaml) - see
// catalog/lib/cdevents.sh for the exact JSON shape this mirrors in Go.
//
// Auth is deliberately NOT the broker's own TokenReview mechanism
// (platform/broker/cmd/token-review-interceptor) - TokenReview can only validate a
// token against its OWN issuing cluster's API server, so it structurally cannot
// authenticate a caller from a genuinely different cluster. Instead: a shared secret
// per upstream cluster (POST /outcome/<cluster>, Authorization: Bearer <token>,
// resolved live via the cluster-registry ConfigMap -> a Secret in this same
// namespace), matching the class of check Tekton Triggers' own built-in `gitlab`
// ClusterInterceptor already does for X-Gitlab-Token.
//
// Trust boundary this establishes: the shared secret proves "this call really came
// from cluster X," not "this event is really about app Y" - the payload's own claimed
// appName/env ride on top of that cluster-level trust unverified by this service.
// That's an intentional, bounded weakening relative to the broker's own TokenReview
// path (which verifies caller identity down to the exact SA), not an oversight: which
// apps can even have a hook Job running on cluster X in the first place is already
// gated by Phase D's PR-review + branch-protection flow, so a compromised cluster
// secret can spoof an outcome, not fabricate a release.
//
// Earlier design history worth knowing before touching this file again (full account
// in docs/multi-cluster.md): a first version had ArgoCD Notifications call here with
// only identity/status fields, and this service fetched the actual per-release data
// from GitHub by git revision, because the Application object's own annotations were
// racy against the app-of-apps root's independent reconcile loop. That entire
// mechanism (GitHub App JWT signing, Contents API fetch, the internal/githubapp
// dependency) was REMOVED once ArgoCD Notifications itself turned out to have a worse
// problem: it fired on ANY completed sync, including pure selfHeal drift-correction
// with zero release involved (confirmed live). Sync-hook Jobs don't have either
// problem - a hook only runs when the resources in ITS OWN sync actually needed
// reapplying (confirmed live: a drift-only sync didn't re-fire one), and everything
// they report is baked in at commit time by the same Task that already has the real
// values in hand. So this service is back to being pure auth-and-forward, the way it
// started - not a coincidence, the simpler shape turned out to be the actually-correct
// one too.
package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	platformNamespace  = "platform-system"
	registryConfigMap  = "cluster-registry"
	brokerTokenPath    = "/var/run/secrets/platform/broker-token"
	eventType          = "dev.cdevents.environment.deployed.0.1.0"
	cdeventsVersion    = "0.4.1"
	requestBodyMaxSize = 1 << 16 // this payload is a handful of short fields, never legitimately larger
)

// Mirrors charts/platform-cicd-control-plane/templates/clusters/cluster-registry.yaml's
// per-cluster JSON value - only the field this service needs out of it.
type registryEntry struct {
	RelaySecretName string `json:"relaySecretName"`
}

// The body catalog/lib/argocd-outcome-hook.sh sends - every field baked in by
// open-release-pr.yaml at commit time, nothing fetched or read live from anywhere by
// either the hook or this service. See this file's own header for why.
type outcomeRequest struct {
	AppNamespace  string `json:"appNamespace"`
	AppName       string `json:"appName"`
	Env           string `json:"env"`
	Phase         string `json:"phase"` // Succeeded or Failed - which hook ran, baked in per-hook-type
	Revision      string `json:"revision"`
	GitURL        string `json:"gitUrl"`
	GitRevision   string `json:"gitRevision"`
	FlowStartTime string `json:"flowStartTime"`
	FinishedAt    string `json:"finishedAt"` // set by the hook script itself (date -u), the moment it actually runs
	ConfigJSONB64 string `json:"configJsonB64"`
}

func main() {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("loading in-cluster config: %v", err)
	}
	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("building clientset: %v", err)
	}

	brokerURL := os.Getenv("CDEVENTS_BROKER_URL")
	if brokerURL == "" {
		log.Fatal("CDEVENTS_BROKER_URL must be set")
	}
	doraExporterURL := os.Getenv("DORA_EXPORTER_URL") // optional - see forwardToDoraExporter, Phase F

	h := &handler{clientset: clientset, brokerURL: brokerURL, doraExporterURL: doraExporterURL, httpClient: &http.Client{Timeout: 10 * time.Second}}

	mux := http.NewServeMux()
	mux.HandleFunc("/outcome/", h.handleOutcome)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	log.Println("argocd-outcome-relay: listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

type handler struct {
	clientset       kubernetes.Interface
	brokerURL       string
	doraExporterURL string
	httpClient      *http.Client
}

func (h *handler) handleOutcome(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	cluster := strings.TrimPrefix(r.URL.Path, "/outcome/")
	if cluster == "" || strings.Contains(cluster, "/") {
		http.Error(w, "cluster name required in path: /outcome/<cluster>", http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	if err := h.authenticate(ctx, cluster, r.Header.Get("Authorization")); err != nil {
		log.Printf("argocd-outcome-relay: auth failed for cluster=%s: %v", cluster, err)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	var req outcomeRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, requestBodyMaxSize)).Decode(&req); err != nil {
		http.Error(w, fmt.Sprintf("invalid request body: %v", err), http.StatusBadRequest)
		return
	}
	if req.AppNamespace == "" || req.AppName == "" || req.Env == "" || req.Phase == "" {
		http.Error(w, "appNamespace, appName, env, and phase are required", http.StatusBadRequest)
		return
	}

	if err := h.forwardToBroker(ctx, cluster, req); err != nil {
		log.Printf("argocd-outcome-relay: forwarding to broker failed (cluster=%s app=%s/%s): %v", cluster, req.AppNamespace, req.AppName, err)
		http.Error(w, "failed to forward event", http.StatusBadGateway)
		return
	}

	// Best-effort, not on the critical path - see docs/multi-cluster.md's Phase F
	// section for why this is a direct call rather than a second broker round trip.
	if h.doraExporterURL != "" {
		if err := h.forwardToDoraExporter(ctx, req); err != nil {
			log.Printf("argocd-outcome-relay: dora-exporter forward failed (non-fatal, app=%s/%s): %v", req.AppNamespace, req.AppName, err)
		}
	}

	w.WriteHeader(http.StatusAccepted)
}

// authenticate resolves cluster -> relaySecretName live off the cluster-registry
// ConfigMap, then compares the caller's bearer token against that Secret's own
// "token" key. Nothing here is cached across requests - this fires on real releases,
// not a hot path, and a live lookup means a rotated/revoked secret takes effect
// immediately with no relay restart, matching this platform's established preference
// for live lookups over baked-in state (see cluster-registry.yaml's own header).
func (h *handler) authenticate(ctx context.Context, cluster, authHeader string) error {
	const prefix = "Bearer "
	if !strings.HasPrefix(authHeader, prefix) {
		return fmt.Errorf("missing or malformed Authorization header")
	}
	provided := strings.TrimPrefix(authHeader, prefix)

	cm, err := h.clientset.CoreV1().ConfigMaps(platformNamespace).Get(ctx, registryConfigMap, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("reading cluster-registry ConfigMap: %w", err)
	}
	raw, ok := cm.Data[cluster]
	if !ok {
		return fmt.Errorf("cluster %q has no cluster-registry entry", cluster)
	}
	var entry registryEntry
	if err := json.Unmarshal([]byte(raw), &entry); err != nil {
		return fmt.Errorf("cluster-registry entry for %q is not valid JSON: %w", cluster, err)
	}
	if entry.RelaySecretName == "" {
		return fmt.Errorf("cluster %q's registry entry has no relaySecretName", cluster)
	}

	secret, err := h.clientset.CoreV1().Secrets(platformNamespace).Get(ctx, entry.RelaySecretName, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("reading relay secret %q for cluster %q: %w", entry.RelaySecretName, cluster, err)
	}
	expected, ok := secret.Data["token"]
	if !ok {
		return fmt.Errorf("secret %q has no 'token' key", entry.RelaySecretName)
	}

	if subtle.ConstantTimeCompare(expected, []byte(provided)) != 1 {
		return fmt.Errorf("token mismatch")
	}
	return nil
}

// forwardToBroker builds a CDEvent matching catalog/lib/cdevents.sh's exact shape
// (context/subject/customData) and POSTs it using this pod's OWN projected
// ServiceAccount token - the same mechanism catalog/tasks/send-cdevent.yaml already
// uses, verified by the broker's existing, unmodified TokenReview interceptor. This
// service's SA lives in platform-system, not the target app's namespace, so
// extensions.app_namespace (which the interceptor sets from the CALLER's own verified
// identity) will read "platform-system" here, never the app's - the new Trigger that
// consumes this event type therefore can't rely on that extension the way every
// per-flow Trigger in flow-triggers.yaml does, and matches on the event's own claimed
// appNamespace field instead. See that Trigger's own CEL filter and this file's header
// for the trust-boundary reasoning.
func (h *handler) forwardToBroker(ctx context.Context, cluster string, req outcomeRequest) error {
	tokenBytes, err := os.ReadFile(brokerTokenPath)
	if err != nil {
		return fmt.Errorf("reading broker token: %w", err)
	}

	source := fmt.Sprintf("/platform-cicd/%s/%s-%s-%s-outcome", req.AppNamespace, cluster, req.AppName, req.Env)
	// Two vocabularies, both included, deliberately not derived from each other
	// downstream: "outcome" is CDEvents' own success/failure convention (matches
	// cdevents_map_outcome in catalog/lib/cdevents.sh), "status" is the
	// Succeeded/Failed vocabulary notify-slack.yaml's status-display switch already
	// expects from every other caller. Tekton Triggers' $(tt.params.x) substitution
	// is plain string interpolation, not a CEL evaluator - there's no ternary
	// available in a TriggerTemplate to derive one from the other, so both are sent
	// pre-computed rather than pushing that mapping onto the Trigger.
	outcome, status := "success", "Succeeded"
	if req.Phase != "Succeeded" {
		outcome, status = "failure", "Failed"
	}
	configJSON := "{}"
	if req.ConfigJSONB64 != "" {
		if decoded, err := base64.StdEncoding.DecodeString(req.ConfigJSONB64); err == nil {
			configJSON = string(decoded)
		} else {
			log.Printf("argocd-outcome-relay: configJsonB64 decode failed (app=%s/%s): %v", req.AppNamespace, req.AppName, err)
		}
	}

	payload := map[string]interface{}{
		"context": map[string]interface{}{
			"version": cdeventsVersion,
			// finishedAt in the id, not just source+eventType - a real bug caught live
			// while verifying this: context.source has no per-attempt uniqueness (it's
			// a fixed string per app/env/cluster, unlike a real PipelineRun's own
			// unique name that cdevents.sh's identical-looking id scheme keys off of),
			// so every distinct release outcome for the same app/env was colliding on
			// the same id - meaning the same downstream pipeline-run-name, meaning
			// only the FIRST ever outcome for a given app/env actually created a
			// release-outcome-notify PipelineRun; every later one silently no-op'd as
			// "already exists" at the Trigger's own admission step. finishedAt makes
			// each genuinely distinct outcome produce a distinct id again, while true
			// redelivery of the SAME outcome (a hook Job retry after a transient
			// relay hiccup, say) stays idempotent, since it'd carry the same
			// finishedAt.
			"id":        deterministicID(source, eventType, req.FinishedAt),
			"source":    source,
			"type":      eventType,
			"timestamp": time.Now().UTC().Format(time.RFC3339),
			"chainId":   "",
		},
		"subject": map[string]interface{}{
			"id":     source,
			"source": source,
			"type":   "environment",
			"content": map[string]interface{}{
				"appNamespace":  req.AppNamespace,
				"appName":       req.AppName,
				"env":           req.Env,
				"cluster":       cluster,
				"phase":         req.Phase,
				"outcome":       outcome,
				"status":        status,
				"revision":      req.Revision,
				"gitUrl":        req.GitURL,
				"gitRevision":   req.GitRevision,
				"flowStartTime": req.FlowStartTime,
				"finishedAt":    req.FinishedAt,
				"configJson":    configJSON,
			},
		},
		"customData": map[string]interface{}{
			"platform": map[string]interface{}{
				"traceparent":     "",
				"flow_start_time": req.FlowStartTime,
				"config_json":     "{}",
			},
		},
		"customDataContentType": "application/json",
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshaling CDEvent: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, h.brokerURL, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tokenBytes)))
	httpReq.Header.Set("Content-Type", "application/cloudevents+json")

	resp, err := h.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("posting to broker: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("broker returned %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// forwardToDoraExporter is a direct, best-effort HTTP call to the DORA exporter's own
// outcome endpoint (Phase F) - deliberately NOT routed through the broker/Tekton
// Trigger path the way the notification consumer is. docs/dora-metrics.md already
// explains why DORA was kept out of the CDEvents-subscriber model originally (avoiding
// PipelineRun overhead for what's fundamentally a metrics update); a direct call here
// is the same reasoning applied to this new path.
func (h *handler) forwardToDoraExporter(ctx context.Context, req outcomeRequest) error {
	payload := map[string]string{
		"appNamespace":  req.AppNamespace,
		"appName":       req.AppName,
		"phase":         req.Phase,
		"finishedAt":    req.FinishedAt,
		"flowStartTime": req.FlowStartTime,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, h.doraExporterURL, strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := h.httpClient.Do(httpReq)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("dora-exporter returned %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// deterministicID mirrors cdevents.sh's own scheme exactly (sha256, truncated to 20
// hex chars - see that file's comment on the 63-char Kubernetes resource-name limit)
// so this event's id is stable across at-least-once redelivery, the same idempotency
// property every other CDEvent in this platform already has.
func deterministicID(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, ":")))
	return hex.EncodeToString(sum[:])[:20]
}

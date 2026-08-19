// Closes the loop on the release stage (docs/admin/multi-cluster.md): an upper-env
// cluster's ArgoCD sync-hook Jobs (catalog/lib/argocd-outcome-hook.sh) POST here once a
// release completes, and this service reshapes that into a CDEvent and forwards it to
// the existing broker (see catalog/lib/cdevents.sh for the JSON shape mirrored here).
//
// Auth is a shared secret per upstream cluster (POST /outcome/<cluster>, resolved live
// via the cluster-registry ConfigMap), not the broker's own TokenReview - TokenReview
// can't validate a token issued by a different cluster's API server. Trust boundary:
// the secret proves the call came from cluster X, not that the payload's claimed
// appName/env are accurate - acceptable because which apps can run a hook Job on
// cluster X is already gated by the PR-review + branch-protection flow, so a
// compromised cluster secret can spoof an outcome, not fabricate a release.
//
// Earlier design fetched release data from GitHub via ArgoCD Notifications callbacks,
// dropped because Notifications fired on any completed sync (including pure selfHeal
// drift-correction with no release involved). Sync-hook Jobs only run when their own
// sync needed reapplying, and already carry the real values baked in at commit time -
// simpler and correct.
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
	requestBodyMaxSize = 1 << 16 // a handful of short fields, never legitimately larger
)

// Mirrors cluster-registry.yaml's per-cluster JSON value - only the field this service needs.
type registryEntry struct {
	RelaySecretName string `json:"relaySecretName"`
}

// The body catalog/lib/argocd-outcome-hook.sh sends - every field baked in at commit
// time by open-release-pr.yaml, nothing fetched live.
type outcomeRequest struct {
	AppNamespace  string `json:"appNamespace"`
	AppName       string `json:"appName"`
	Env           string `json:"env"`
	Phase         string `json:"phase"` // Succeeded or Failed - which hook ran
	Revision      string `json:"revision"`
	GitURL        string `json:"gitUrl"`
	GitRevision   string `json:"gitRevision"`
	FlowStartTime string `json:"flowStartTime"`
	FinishedAt    string `json:"finishedAt"` // set by the hook script (date -u) when it runs
	PRUrl         string `json:"prUrl"`      // the GitOps PR this hook Job came from
	ConfigJSONB64 string `json:"configJsonB64"`
	ChainID       string `json:"chainId"`     // optional - apps onboarded before this field existed omit it
	PRCreatedAt   string `json:"prCreatedAt"` // optional, same reasoning
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

	// Best-effort, not on the critical path - a direct call rather than a second
	// broker round trip (docs/admin/multi-cluster.md).
	if h.doraExporterURL != "" {
		if err := h.forwardToDoraExporter(ctx, req); err != nil {
			log.Printf("argocd-outcome-relay: dora-exporter forward failed (non-fatal, app=%s/%s): %v", req.AppNamespace, req.AppName, err)
		}
	}

	w.WriteHeader(http.StatusAccepted)
}

// authenticate resolves cluster -> relaySecretName live off the cluster-registry
// ConfigMap, then compares the caller's bearer token against that Secret's "token" key.
// Not cached - this isn't a hot path, and a live lookup lets a rotated/revoked secret
// take effect without a relay restart.
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

// forwardToBroker builds a CDEvent matching cdevents.sh's shape and POSTs it using this
// pod's own projected SA token, verified by the broker's existing TokenReview
// interceptor. Since this SA lives in platform-system, not the app's namespace,
// extensions.app_namespace will read "platform-system" here - the consuming Trigger
// matches on the event's claimed appNamespace field instead (see this file's header).
func (h *handler) forwardToBroker(ctx context.Context, cluster string, req outcomeRequest) error {
	tokenBytes, err := os.ReadFile(brokerTokenPath)
	if err != nil {
		return fmt.Errorf("reading broker token: %w", err)
	}

	source := fmt.Sprintf("/platform-cicd/%s/%s-%s-%s-outcome", req.AppNamespace, cluster, req.AppName, req.Env)
	// Two vocabularies sent pre-computed, not derived from each other downstream:
	// "outcome" is CDEvents' success/failure convention, "status" is the
	// Succeeded/Failed vocabulary notify-slack.yaml expects. Tekton Triggers'
	// $(tt.params.x) is plain string substitution with no ternary to derive one from
	// the other in a TriggerTemplate.
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
			// finishedAt is part of the id, not just source+eventType: context.source
			// is a fixed string per app/env/cluster (no per-attempt uniqueness), so
			// without finishedAt every distinct release outcome for the same app/env
			// collided on the same id and only the first ever created a
			// release-outcome-notify PipelineRun - later ones silently no-op'd as
			// "already exists". A true redelivery of the same outcome still carries
			// the same finishedAt, so idempotency is preserved.
			"id":        deterministicID(source, eventType, req.FinishedAt),
			"source":    source,
			"type":      eventType,
			"timestamp": time.Now().UTC().Format(time.RFC3339),
			// The original flow's chain-id, not a fresh one, so release-outcome-span.yaml
			// can tag its own span with the same chain-id and stay findable alongside
			// the rest of the flow's spans in Grafana. Empty for apps onboarded before
			// this field existed.
			"chainId": req.ChainID,
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
				"prUrl":         req.PRUrl,
				"configJson":    configJSON,
				// The real start anchor for release-outcome-span.yaml's span - lead
				// time is measured from PR-creation, not flowStartTime above. Empty
				// for apps onboarded before this field existed.
				"prCreatedAt": req.PRCreatedAt,
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

// forwardToDoraExporter is a direct, best-effort HTTP call to the DORA exporter's
// outcome endpoint, not routed through the broker/Tekton Trigger path - avoids
// PipelineRun overhead for what's fundamentally a metrics update.
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

// deterministicID mirrors cdevents.sh's scheme (sha256 truncated to 20 hex chars, to
// fit Kubernetes' 63-char resource-name limit) so the id is stable across at-least-once
// redelivery.
func deterministicID(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, ":")))
	return hex.EncodeToString(sum[:])[:20]
}

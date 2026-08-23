// Closes the loop on the release stage (docs/admin/multi-cluster.md): an upper-env
// cluster's ArgoCD sync-hook Jobs (catalog/lib/argocd-outcome-hook.sh) POST a
// ready-made CDEvent here once a release completes, and this service forwards it
// unchanged to the existing broker - see catalog/lib/argocd-outcome-hook.sh for the
// JSON shape (mirrors catalog/lib/cdevents.sh's, built there rather than here since
// this service used to duplicate that shaping logic in Go).
//
// Auth is a shared secret per upstream cluster (POST /outcome/<cluster>, resolved live
// via the cluster-registry ConfigMap), not the broker's own TokenReview - TokenReview
// can't validate a token issued by a different cluster's API server. Trust boundary:
// the secret proves the call came from cluster X, not that the payload's claimed
// appName/env are accurate - acceptable because which apps can run a hook Job on
// cluster X is already gated by the PR-review + branch-protection flow, so a
// compromised cluster secret can spoof an outcome, not fabricate a release.
//
// One field IS still checked, not just passed through: subject.content.cluster must
// match the <cluster> the URL path authenticated against. Every other field is a
// self-asserted claim by the hook script (same trust boundary as before) - but
// "which cluster is this" is exactly what the shared-secret lookup above already
// proved, so silently trusting a different, self-asserted value there would let a
// compromised app namespace on cluster X claim an outcome for cluster Y. Cheap
// integrity check, not decoration.
//
// Earlier design fetched release data from GitHub via ArgoCD Notifications callbacks,
// dropped because Notifications fired on any completed sync (including pure selfHeal
// drift-correction with no release involved). Sync-hook Jobs only run when their own
// sync needed reapplying, and already carry the real values baked in at commit time -
// simpler and correct.
package main

import (
	"context"
	"crypto/subtle"
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
	requestBodyMaxSize = 1 << 16 // a handful of short fields, never legitimately larger
)

// Mirrors cluster-registry.yaml's per-cluster JSON value - only the field this service needs.
type registryEntry struct {
	RelaySecretName string `json:"relaySecretName"`
}

// Just enough of the hook script's CDEvent envelope to validate the claimed cluster
// and to feed the best-effort dora-exporter forward below - this service otherwise
// treats the body as opaque bytes it doesn't need to understand.
type cdEventEnvelope struct {
	Subject struct {
		Content struct {
			Cluster       string `json:"cluster"`
			AppNamespace  string `json:"appNamespace"`
			AppName       string `json:"appName"`
			Phase         string `json:"phase"`
			FinishedAt    string `json:"finishedAt"`
			FlowStartTime string `json:"flowStartTime"`
		} `json:"content"`
	} `json:"subject"`
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

	body, err := io.ReadAll(io.LimitReader(r.Body, requestBodyMaxSize))
	if err != nil {
		http.Error(w, fmt.Sprintf("reading request body: %v", err), http.StatusBadRequest)
		return
	}
	var env cdEventEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		http.Error(w, fmt.Sprintf("invalid CDEvent JSON: %v", err), http.StatusBadRequest)
		return
	}
	if env.Subject.Content.Cluster != cluster {
		http.Error(w, fmt.Sprintf("event claims cluster %q, authenticated as %q", env.Subject.Content.Cluster, cluster), http.StatusBadRequest)
		return
	}

	if err := h.forwardToBroker(ctx, body); err != nil {
		log.Printf("argocd-outcome-relay: forwarding to broker failed (cluster=%s app=%s/%s): %v", cluster, env.Subject.Content.AppNamespace, env.Subject.Content.AppName, err)
		http.Error(w, "failed to forward event", http.StatusBadGateway)
		return
	}

	// Best-effort, not on the critical path - a direct call rather than a second
	// broker round trip (docs/admin/multi-cluster.md).
	if h.doraExporterURL != "" {
		if err := h.forwardToDoraExporter(ctx, env); err != nil {
			log.Printf("argocd-outcome-relay: dora-exporter forward failed (non-fatal, app=%s/%s): %v", env.Subject.Content.AppNamespace, env.Subject.Content.AppName, err)
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

// forwardToBroker POSTs the hook script's own CDEvent bytes to the broker unchanged,
// swapping in this pod's own projected SA token (verified by the broker's existing
// TokenReview interceptor) in place of the shared-secret auth this call arrived with.
func (h *handler) forwardToBroker(ctx context.Context, body []byte) error {
	tokenBytes, err := os.ReadFile(brokerTokenPath)
	if err != nil {
		return fmt.Errorf("reading broker token: %w", err)
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
func (h *handler) forwardToDoraExporter(ctx context.Context, env cdEventEnvelope) error {
	payload := map[string]string{
		"appNamespace":  env.Subject.Content.AppNamespace,
		"appName":       env.Subject.Content.AppName,
		"phase":         env.Subject.Content.Phase,
		"finishedAt":    env.Subject.Content.FinishedAt,
		"flowStartTime": env.Subject.Content.FlowStartTime,
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

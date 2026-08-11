// platform/dora-exporter/cmd/dora-exporter/main.go
//
// Two input paths feeding the same four DORA metrics, not one:
//
//  1. Same-cluster envs (no cluster: in deploy.upperEnvironments): watches ArgoCD
//     Application objects directly (applications.argoproj.io, in the argocd
//     namespace, filtered to platform.io/dora-track=true) for confirmed terminal sync
//     outcomes - unchanged since this service's original design. See
//     docs/dora-metrics.md for the full mechanism and why this watches ArgoCD
//     directly instead of subscribing to the CDEvents broker like the original
//     architecture plan assumed.
//  2. Cluster-mapped envs (Phase 3 item 4, docs/multi-cluster.md): a small HTTP
//     endpoint (/argocd-outcome) that platform/broker/cmd/argocd-outcome-relay calls
//     directly once an upper cluster's ArgoCD confirms a real outcome - this service
//     has no live API access to a remote cluster's Application object, so there's
//     nothing to watch there. NOT a replacement for path 1 - same-cluster
//     Applications still live in THIS cluster's argocd namespace and the informer is
//     still the right tool for them.
//
// Both paths funnel into the same recordOutcome() - the actual metric-recording logic
// doesn't care which path it came from. What's genuinely different: path 1 can (and
// does) patch a "last failure time" annotation back onto the live Application object
// for later MTTR correlation; path 2 has no such object to patch (same "no direct API
// access to a remote cluster" principle as everywhere else in this feature - see
// mark-release-pending.yaml), so MTTR is a known, deliberate gap for cluster-mapped
// apps in this pass, not silently dropped - see recordOutcome's own comment.
//
// Correlation with a specific release attempt happens via the platform.io/dora-*
// annotations the release Pipeline stamps directly onto the Application object
// (catalog/tasks/mark-release-pending.yaml for path 1, open-release-pr.yaml's
// GitOps-committed manifest for path 2) - not a separate datastore, not image/revision
// matching (status.summary.images is empty on this ArgoCD install - checked live
// before this was designed, see docs/dora-metrics.md).
//
// Same dynamic-client + GVR pattern platform/broker/cmd/token-review-interceptor/main.go
// already uses for the pipelinesascode.tekton.dev Repository CRD - proven in this exact
// codebase, not a new one.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
)

var applicationGVR = schema.GroupVersionResource{Group: "argoproj.io", Version: "v1alpha1", Resource: "applications"}

const (
	annoPending            = "platform.io/dora-pending"
	annoFlowStartTime      = "platform.io/dora-flow-start-time"
	annoBaselineStartedAt  = "platform.io/dora-baseline-started-at"
	annoAppNamespace       = "platform.io/dora-app-namespace"
	annoApp                = "platform.io/dora-app"
	annoLastFailureTime    = "platform.io/dora-last-failure-time"
	argocdNamespace        = "argocd"
	doraTrackLabelSelector = "platform.io/dora-track=true"
)

// Lead Time buckets are deliberately aligned to DORA's own published elite/high/medium/
// low bands (1h/1d/1w/1mo) so histogram_quantile() in Grafana directly shows which band
// most changes fall into - not an arbitrary Prometheus default bucket set.
var leadTimeBuckets = []float64{3600, 86400, 604800, 2592000}

// MTTR buckets are sized for human-response-time scale (minutes to a week), not
// deploy-time scale - a different shape of measurement than lead time.
var mttrBuckets = []float64{300, 1800, 3600, 14400, 86400, 604800}

var (
	deploymentsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "dora_deployments_total",
		Help: "Confirmed successful releases (ArgoCD sync Succeeded), by app_namespace/app. Deployment Frequency is increase() over this in Grafana, not precomputed here.",
	}, []string{"app_namespace", "app"})

	leadTimeSeconds = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "dora_lead_time_seconds",
		Help:    "Time from a flow's original commit-triggered start (build's start-flow-root-span) to confirmed ArgoCD sync success.",
		Buckets: leadTimeBuckets,
	}, []string{"app_namespace", "app"})

	releasesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "dora_releases_total",
		Help: "Every confirmed terminal release outcome, by app_namespace/app/outcome (succeeded|failed). Change Failure Rate is failed/total in Grafana.",
	}, []string{"app_namespace", "app", "outcome"})

	// _experimental is deliberate and structural, not just a dashboard note - this
	// platform has no incident-tracking or production-health signal, so this can only
	// ever measure "time to next confirmed successful release for this app", not a true
	// incident MTTR. Same honest caveat the architecture plan already applied to this
	// metric from the start.
	timeToRestoreSecondsExperimental = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "dora_time_to_restore_seconds_experimental",
		Help:    "Time between a confirmed failed release and the next confirmed successful one for the same app. Best-effort - cannot see rollbacks/fixes that happen outside this pipeline.",
		Buckets: mttrBuckets,
	}, []string{"app_namespace", "app"})
)

func init() {
	prometheus.MustRegister(deploymentsTotal, leadTimeSeconds, releasesTotal, timeToRestoreSecondsExperimental)
}

func main() {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("in-cluster config: %v", err)
	}
	dynClient, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("dynamic client: %v", err)
	}

	factory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(
		dynClient, 10*time.Minute, argocdNamespace,
		func(opts *metav1.ListOptions) { opts.LabelSelector = doraTrackLabelSelector },
	)
	informer := factory.ForResource(applicationGVR).Informer()

	handler := func(obj interface{}) {
		u, ok := obj.(*unstructured.Unstructured)
		if !ok {
			return
		}
		reconcile(context.Background(), dynClient, u)
	}
	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: handler,
		// Add fires for every already-existing matching Application on startup too -
		// deliberately reused here so a restart correctly catches up on any release
		// that was confirmed by ArgoCD while this service was down, rather than losing
		// it silently.
		UpdateFunc: func(_, newObj interface{}) { handler(newObj) },
	})

	stop := make(chan struct{})
	defer close(stop)
	factory.Start(stop)
	if !cache.WaitForCacheSync(stop, informer.HasSynced) {
		log.Fatal("failed to sync informer cache")
	}
	log.Println("dora-exporter: informer cache synced, watching applications.argoproj.io in argocd (platform.io/dora-track=true)")

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/argocd-outcome", handleArgoCDOutcome)
	log.Println("dora-exporter: listening on :8080 (/metrics, /argocd-outcome)")
	log.Fatal(http.ListenAndServe(":8080", mux))
}

// argocdOutcomeRequest mirrors argocd-outcome-relay's own outcomeRequest shape (the
// relay forwards close to what it itself received, adding nothing dora-exporter-
// specific) - see platform/broker/cmd/argocd-outcome-relay/main.go.
type argocdOutcomeRequest struct {
	AppNamespace  string `json:"appNamespace"`
	AppName       string `json:"appName"`
	Phase         string `json:"phase"`
	FinishedAt    string `json:"finishedAt"`
	FlowStartTime string `json:"flowStartTime"`
}

// handleArgoCDOutcome is path 2 from this file's own header - no informer, no
// annotation patch-back (nothing to patch on a cluster this service has no API access
// to), just the same terminal-phase metric recording the informer path already does.
// Trusts its caller (argocd-outcome-relay, an in-cluster peer in platform-system) -
// this endpoint isn't independently authenticated; the relay is the trust boundary
// for this whole path, same as it is for the broker forward - see that service's own
// header for the reasoning.
func handleArgoCDOutcome(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req argocdOutcomeRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.AppNamespace == "" || req.AppName == "" || req.Phase == "" {
		http.Error(w, "appNamespace, appName, and phase are required", http.StatusBadRequest)
		return
	}
	if !isTerminalPhase(req.Phase) {
		w.WriteHeader(http.StatusAccepted) // not an error - just nothing to record yet
		return
	}
	finishedAt, err := parseTime(req.FinishedAt)
	if err != nil {
		http.Error(w, "unparseable finishedAt", http.StatusBadRequest)
		return
	}
	recordOutcome(req.AppNamespace, req.AppName, req.Phase, finishedAt, req.FlowStartTime, "" /* no lastFailureTime source - see this file's header */)
	log.Printf("dora-exporter: %s/%s: recorded %s via /argocd-outcome (cluster-mapped env)", req.AppNamespace, req.AppName, req.Phase)
	w.WriteHeader(http.StatusAccepted)
}

// reconcile implements the annotation-based hand-off described in
// catalog/tasks/mark-release-pending.yaml and docs/dora-metrics.md. It is safe to call
// repeatedly for the same object state: once dora-pending is cleared (by this function's
// own patch), the next informer event for that same change carries no dora-pending
// annotation, so the early return below makes it a no-op - no separate dedup tracking
// needed beyond the annotations themselves.
func reconcile(ctx context.Context, dynClient dynamic.Interface, app *unstructured.Unstructured) {
	annos := app.GetAnnotations()
	if annos[annoPending] != "true" {
		return
	}

	phase, _, _ := unstructured.NestedString(app.Object, "status", "operationState", "phase")
	startedAtStr, _, _ := unstructured.NestedString(app.Object, "status", "operationState", "startedAt")
	finishedAtStr, _, _ := unstructured.NestedString(app.Object, "status", "operationState", "finishedAt")

	if !isTerminalPhase(phase) {
		return // still Running/Terminating/unset - not our moment yet
	}

	startedAt, err := parseTime(startedAtStr)
	if err != nil {
		log.Printf("dora-exporter: %s/%s: unparseable operationState.startedAt %q, skipping", app.GetNamespace(), app.GetName(), startedAtStr)
		return
	}

	// The baseline check: operationState gets overwritten by ANY sync, including
	// ArgoCD's own unrelated selfHeal drift-correction syncs. Only react once a sync
	// STRICTLY NEWER than the one recorded at pending-time appears - otherwise this
	// would react to a sync that had already finished before this release attempt even
	// started. An empty baseline (the Application had no operationState at all yet when
	// mark-release-pending ran) means anything terminal now counts.
	if baselineStr := annos[annoBaselineStartedAt]; baselineStr != "" {
		baseline, err := parseTime(baselineStr)
		if err == nil && !startedAt.After(baseline) {
			return // this is the same (or an older) sync we already had a baseline for
		}
	}

	finishedAt, err := parseTime(finishedAtStr)
	if err != nil {
		log.Printf("dora-exporter: %s/%s: unparseable operationState.finishedAt %q, skipping", app.GetNamespace(), app.GetName(), finishedAtStr)
		return
	}

	appNamespace := annos[annoAppNamespace]
	appName := annos[annoApp]

	patch := map[string]interface{}{annoPending: nil} // JSON merge patch: null removes the key
	lastFailureCleared := recordOutcome(appNamespace, appName, phase, finishedAt, annos[annoFlowStartTime], annos[annoLastFailureTime])
	if phase == "Succeeded" && lastFailureCleared {
		patch[annoLastFailureTime] = nil
	} else if phase == "Failed" || phase == "Error" {
		patch[annoLastFailureTime] = finishedAt.Format(time.RFC3339)
	}
	log.Printf("dora-exporter: %s/%s: confirmed %s via informer (same-cluster env)", app.GetNamespace(), app.GetName(), phase)

	if err := patchAnnotations(ctx, dynClient, app.GetNamespace(), app.GetName(), patch); err != nil {
		log.Printf("dora-exporter: %s/%s: failed to clear tracking annotations: %v", app.GetNamespace(), app.GetName(), err)
	}
}

// recordOutcome is the one piece of actual DORA business logic, shared by both input
// paths described in this file's own header. lastFailureTimeStr is only ever non-empty
// on the informer path (path 1) - path 2 always passes "", which simply means an
// eventual success for a cluster-mapped app never produces an MTTR sample (returns
// false so the informer-only caller knows there was nothing to clear) - a known,
// deliberate gap (this file's header), not a silent one: there's no live Application
// object on a remote cluster for this service to persist "last failure time" onto
// between separate HTTP calls, and an in-memory map would be wrong the moment this
// Deployment runs more than one replica or restarts - not worth that fragility for a
// best-effort, already-`_experimental` metric. Returns whether a prior failure was
// found and consumed (path 1 uses this to decide whether to clear its own annotation).
func recordOutcome(appNamespace, appName, phase string, finishedAt time.Time, flowStartTimeStr, lastFailureTimeStr string) bool {
	switch phase {
	case "Succeeded":
		releasesTotal.WithLabelValues(appNamespace, appName, "succeeded").Inc()
		deploymentsTotal.WithLabelValues(appNamespace, appName).Inc()

		if flowStart, err := parseTime(flowStartTimeStr); err == nil {
			leadTimeSeconds.WithLabelValues(appNamespace, appName).Observe(finishedAt.Sub(flowStart).Seconds())
		} else {
			log.Printf("dora-exporter: %s/%s: unparseable flow-start-time %q, skipping lead-time sample", appNamespace, appName, flowStartTimeStr)
		}

		if lastFailureTimeStr != "" {
			if lastFailure, err := parseTime(lastFailureTimeStr); err == nil {
				if mttr := finishedAt.Sub(lastFailure).Seconds(); mttr > 0 {
					timeToRestoreSecondsExperimental.WithLabelValues(appNamespace, appName).Observe(mttr)
				}
			}
			return true
		}
		return false

	case "Failed", "Error":
		releasesTotal.WithLabelValues(appNamespace, appName, "failed").Inc()
		return false
	}
	return false
}

func isTerminalPhase(phase string) bool {
	return phase == "Succeeded" || phase == "Failed" || phase == "Error"
}

func parseTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, errors.New("empty timestamp")
	}
	return time.Parse(time.RFC3339, s)
}

func patchAnnotations(ctx context.Context, dynClient dynamic.Interface, namespace, name string, annos map[string]interface{}) error {
	patch := map[string]interface{}{
		"metadata": map[string]interface{}{
			"annotations": annos,
		},
	}
	body, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	_, err = dynClient.Resource(applicationGVR).Namespace(namespace).Patch(ctx, name, types.MergePatchType, body, metav1.PatchOptions{})
	return err
}

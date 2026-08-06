// platform/dora-exporter/cmd/dora-exporter/main.go
//
// Watches ArgoCD Application objects (applications.argoproj.io, in the argocd
// namespace, filtered to platform.io/dora-track=true) for confirmed terminal sync
// outcomes, and turns them into the four DORA metrics. See docs/dora-metrics.md for the
// full mechanism and why this watches ArgoCD directly instead of subscribing to the
// CDEvents broker like the original architecture plan assumed: CDEvents can currently
// only tell us a release PR was opened, not whether it was ever merged or whether
// ArgoCD's sync of it actually succeeded - both of which every one of these metrics
// needs. This deliberately does NOT touch catalog/lib/cdevents.sh or send-cdevent.yaml,
// the shared library every pipeline stage's finally block depends on for real chaining -
// a metrics feature has no business adding risk to that path.
//
// Correlation with a specific release attempt happens via annotations the release
// Pipeline stamps directly onto its own Application's ArgoCD Application object
// (catalog/tasks/mark-release-pending.yaml), read back here off the same object this
// service is already watching - not a separate datastore, not image/revision matching
// (status.summary.images is empty on this ArgoCD install - checked live before this was
// designed, see docs/dora-metrics.md).
//
// Same dynamic-client + GVR pattern platform/broker/cmd/token-review-interceptor/main.go
// already uses for the pipelinesascode.tekton.dev Repository CRD - proven in this exact
// codebase, not a new one.
package main

import (
	"context"
	"encoding/json"
	"errors"
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
	log.Fatal(http.ListenAndServe(":8080", mux))
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

	switch phase {
	case "Succeeded":
		releasesTotal.WithLabelValues(appNamespace, appName, "succeeded").Inc()
		deploymentsTotal.WithLabelValues(appNamespace, appName).Inc()

		if flowStart, err := parseTime(annos[annoFlowStartTime]); err == nil {
			leadTimeSeconds.WithLabelValues(appNamespace, appName).Observe(finishedAt.Sub(flowStart).Seconds())
		} else {
			log.Printf("dora-exporter: %s/%s: unparseable %s %q, skipping lead-time sample", app.GetNamespace(), app.GetName(), annoFlowStartTime, annos[annoFlowStartTime])
		}

		if lastFailureStr := annos[annoLastFailureTime]; lastFailureStr != "" {
			if lastFailure, err := parseTime(lastFailureStr); err == nil {
				if mttr := finishedAt.Sub(lastFailure).Seconds(); mttr > 0 {
					timeToRestoreSecondsExperimental.WithLabelValues(appNamespace, appName).Observe(mttr)
				}
			}
			patch[annoLastFailureTime] = nil
		}

		log.Printf("dora-exporter: %s/%s: confirmed Succeeded, recorded deployment + lead time", app.GetNamespace(), app.GetName())

	case "Failed", "Error":
		releasesTotal.WithLabelValues(appNamespace, appName, "failed").Inc()
		patch[annoLastFailureTime] = finishedAt.Format(time.RFC3339)
		log.Printf("dora-exporter: %s/%s: confirmed %s, recorded release failure", app.GetNamespace(), app.GetName(), phase)
	}

	if err := patchAnnotations(ctx, dynClient, app.GetNamespace(), app.GetName(), patch); err != nil {
		log.Printf("dora-exporter: %s/%s: failed to clear tracking annotations: %v", app.GetNamespace(), app.GetName(), err)
	}
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

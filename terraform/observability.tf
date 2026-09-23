# Prometheus + Grafana, via kube-prometheus-stack.
#
# Why this exists alongside cloud-observability-sre: that repo does the same job
# with CloudWatch, on a serverless stack. This is the open-source stack on
# Kubernetes, which is what most teams running EKS actually operate — and the two
# answer the same questions with completely different primitives. The comparison
# is written up in docs/observability.md.
#
# Cost note: everything here runs in-cluster on capacity that already exists.
# There is no managed Prometheus (AMP) and no managed Grafana workspace, both of
# which bill separately. Retention is deliberately short and storage is an
# emptyDir, because this cluster is built, measured and destroyed.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "77.6.2"

  # Templating this rather than inlining `set` blocks: the values are nested
  # deeply enough that a flat key list would be unreadable, and YAML is how the
  # chart's own documentation describes them.
  values = [yamlencode({
    fullnameOverride = "kps"

    prometheus = {
      prometheusSpec = {
        retention     = "6h"
        retentionSize = "2GB"
        # Discover ServiceMonitors in every namespace, not just this chart's own
        # release. Without this the app's ServiceMonitor is silently ignored —
        # the single most common reason "Prometheus isn't scraping my service".
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
        podMonitorSelectorNilUsesHelmValues     = false
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
    }

    grafana = {
      # No LoadBalancer and no public ingress: reach it with
      #   kubectl -n monitoring port-forward svc/kps-grafana 3000:80
      # An internet-facing Grafana is a credentialled window onto every metric
      # in the cluster.
      service = { type = "ClusterIP" }
      # Dashboards are provisioned from a ConfigMap built out of dashboards/ in
      # this repo, so they are version-controlled rather than clicked together
      # and lost when the pod restarts.
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          searchNamespace = "ALL"
        }
      }
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }

    # The cluster already has metrics-server for the HPA; kube-state-metrics and
    # node-exporter are what make node and workload state queryable.
    kubeStateMetrics = { enabled = true }
    nodeExporter     = { enabled = true }

    # Alertmanager is disabled: there is nowhere to route a page on a cluster that
    # exists for a few hours. The PrometheusRules still evaluate and show as
    # firing in the UI, which is what the drill needs.
    alertmanager = { enabled = false }
  })]

  depends_on = [module.eks]
}


# The dashboard lives in dashboards/ as JSON and is provisioned through a
# ConfigMap the Grafana sidecar watches. The alternative — building it in the UI —
# loses it the moment the pod restarts, and leaves no way to review a change to it.
resource "kubernetes_config_map" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboard-web"
    namespace = "monitoring"
    labels = {
      # The label the sidecar selects on; set in the helm values above.
      grafana_dashboard = "1"
    }
  }

  data = {
    "web-golden-signals.json" = file("${path.module}/../dashboards/web-golden-signals.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

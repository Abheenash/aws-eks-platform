# Argo CD — GitOps delivery.
#
# The pipeline in .github/workflows/deploy.yml pushes with `kubectl apply`, which
# means CI holds cluster-admin and the cluster's real state is whatever the last
# run left behind. Argo CD inverts that: the repo is the desired state, the
# controller reconciles continuously from inside the cluster, and drift is both
# visible and self-healing. CI's job shrinks to "build the image and update the
# tag in git" — it no longer needs kubectl access at all.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.1.0"

  set = [
    # No public LoadBalancer: reach the UI with `kubectl port-forward`. An
    # internet-facing Argo CD is a cluster-admin console on the open internet.
    { name = "server.service.type", value = "ClusterIP" },
    { name = "configs.params.server\\.insecure", value = "true" },
    # Self-heal and prune are what make this GitOps rather than a one-shot sync.
    { name = "controller.replicas", value = "1" },
  ]

  depends_on = [module.eks]
}

# The app-of-apps root. Argo CD watches this one Application, which points at
# gitops/apps/ in this repo; every workload added there is picked up without
# another terraform apply.
resource "helm_release" "argocd_root_app" {
  name      = "root-app"
  namespace = "argocd"
  chart     = "${path.module}/../gitops/root-app"

  depends_on = [helm_release.argocd]
}

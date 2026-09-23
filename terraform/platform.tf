# Platform layer: the AWS Load Balancer Controller (turns Ingress objects into
# ALBs) and the Metrics Server (feeds CPU metrics to the HorizontalPodAutoscaler).

# The controller's IAM comes from EKS Pod Identity, not IRSA. The role trusts
# pods.eks.amazonaws.com and is bound to a namespace/service-account by an
# association resource below — so the trust policy carries no OIDC issuer URL
# and the same role definition works unchanged if the cluster is rebuilt.
module "alb_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                            = "${local.name}-alb-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    main = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = local.tags
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.14.0"

  # helm provider v3: `set` is a list of objects, not repeated blocks.
  set = [
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "region", value = var.region },
    { name = "vpcId", value = module.vpc.vpc_id },
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
  ]

  depends_on = [module.eks, module.alb_pod_identity]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.13.0"

  set = [
    { name = "args[0]", value = "--kubelet-insecure-tls" },
  ]

  depends_on = [module.eks]
}

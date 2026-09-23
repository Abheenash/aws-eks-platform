# Karpenter — just-in-time node provisioning.
#
# Replaces the fixed-size managed node group as the way workload capacity is
# added. Cluster Autoscaler could only grow an ASG of one instance type; Karpenter
# picks the instance type per pending pod, defaults to Spot, and consolidates
# under-used nodes away. The `system` node group in eks.tf stays as the place
# Karpenter's own controller runs, so the thing that creates nodes never depends
# on a node it created.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Pod Identity instead of IRSA — same reasoning as the ALB controller.
  create_pod_identity_association = true

  # Karpenter watches an SQS queue for Spot interruption and rebalance notices
  # so it can cordon and drain a node in the ~2 minutes before EC2 reclaims it.
  enable_spot_termination = true

  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${local.name}-karpenter-node"
  create_node_iam_role            = true
  node_iam_role_attach_cni_policy = true

  tags = local.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.8.1"
  wait       = true

  set = [
    { name = "settings.clusterName", value = module.eks.cluster_name },
    { name = "settings.interruptionQueue", value = module.karpenter.queue_name },
    { name = "serviceAccount.name", value = "karpenter" },
    # Pin the controller to the system node group so Karpenter can never be
    # evicted onto a node it is itself responsible for.
    { name = "controller.resources.requests.cpu", value = "200m" },
    { name = "controller.resources.requests.memory", value = "256Mi" },
  ]

  depends_on = [module.eks, module.karpenter]
}

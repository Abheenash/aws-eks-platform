module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.cluster_version

  # Public API endpoint so kubectl works from a laptop / CI without a bastion.
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # Core addons the cluster needs to be functional. The Pod Identity agent
  # replaces IRSA: workloads get IAM through an EKS API association rather than
  # an OIDC trust policy, so there is no per-cluster OIDC provider to manage and
  # the role trust document no longer hard-codes a namespace/service-account pair.
  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # A small on-demand node group is kept as the control plane for cluster-critical
  # add-ons (Karpenter itself, CoreDNS). Everything else is scheduled onto Karpenter
  # nodes, which are provisioned just-in-time and default to Spot — see karpenter.tf.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_desired
    }
  }

  # Grant the GitHub Actions deploy role kubectl access to the cluster via a
  # modern EKS access entry (not the legacy aws-auth ConfigMap).
  access_entries = {
    ci = {
      principal_arn = var.deploy_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = local.tags
}

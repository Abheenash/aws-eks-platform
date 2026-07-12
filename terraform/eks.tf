module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.name
  cluster_version = var.cluster_version

  # Public API endpoint so kubectl works from a laptop / CI without a bastion.
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Core addons the cluster needs to be functional.
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
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

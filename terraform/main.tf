provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = var.name_prefix
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
  tags = {
    Project   = "aws-eks-platform"
    ManagedBy = "terraform"
  }
}

# The kubernetes + helm providers authenticate to the cluster with a short-lived
# token minted by the AWS CLI (`aws eks get-token`) — no kubeconfig on disk, no
# static credentials. Values come from the EKS module outputs.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

# helm provider v3 moved to the plugin framework: `kubernetes` is a nested
# object attribute now, not a block.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

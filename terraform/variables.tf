variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Name prefix for all resources (also the EKS cluster name)"
  type        = string
  default     = "eks-platform"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group"
  type        = string
  default     = "t3.small"
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 3
}

variable "deploy_role_arn" {
  description = "GitHub Actions deploy role granted kubectl access via an EKS access entry"
  type        = string
  default     = "arn:aws:iam::638515252275:role/aws-eks-platform-deploy"
}

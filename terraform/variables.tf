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
  description = "EKS Kubernetes version (must be in EKS standard support — 1.31 fell out of it on 2025-11-25)"
  type        = string
  default     = "1.35"

  # This repo sat on 1.31 for months after it left standard support, silently
  # paying $0.60/cluster/hour for extended support and receiving no patches,
  # because nothing failed. A README cannot fail a plan; this can.
  #
  # Update the list deliberately when AWS publishes a new support window — that
  # edit is the point, because it makes the version a decision someone made
  # rather than a default nobody revisited.
  # EKS standard support as of 2026-09: 1.34, 1.35, 1.36.
  validation {
    condition     = contains(["1.34", "1.35", "1.36"], var.cluster_version)
    error_message = "cluster_version must be in EKS standard support (1.34, 1.35 or 1.36 as of 2026-09). Outside that window the cluster moves to paid extended support and stops receiving patches."
  }
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

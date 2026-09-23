# Native terraform tests (`terraform test`).
#
# The EKS and Karpenter modules are third-party and build their IAM from data
# sources a mocked provider cannot satisfy, so a full mocked plan of this root
# module is not useful — and testing someone else's module is not this repo's job
# anyway. What IS this repo's job is the input contract, which is what these
# assert, using `terraform test`'s ability to check that a validation rejects what
# it is supposed to reject.

# Mocked so the plan needs no credentials. Without these the test passes on a
# developer's laptop (which has AWS config) and fails in CI (which does not) —
# a test that depends on who is running it is not a test.
mock_provider "aws" {
  # main.tf slices the first two AZs; a mocked data source returns an empty list,
  # so slice() errors before any assertion can run.
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b"] }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}

# The EKS, Karpenter and pod-identity modules are third-party and build IAM from
# data sources a mocked provider cannot satisfy. Nothing asserted here touches
# them — these tests are about this repo's INPUT CONTRACT — so they are replaced
# wholesale rather than mocked resource by resource.
override_module {
  target  = module.eks
  outputs = {}
}

override_module {
  target  = module.vpc
  outputs = {}
}

override_module {
  target  = module.karpenter
  outputs = {}
}

override_module {
  target  = module.alb_pod_identity
  outputs = {}
}

variables {
  cluster_version = "1.35"
}

run "rejects_a_kubernetes_version_out_of_standard_support" {
  command = plan

  variables {
    # The exact version this repo was actually stranded on. Standard support for
    # 1.31 ended 2025-11-25; the cluster was on paid extended support and nothing
    # in the build noticed.
    cluster_version = "1.31"
  }

  expect_failures = [var.cluster_version]
}

run "rejects_a_version_that_does_not_exist_yet" {
  command = plan

  variables {
    cluster_version = "1.99"
  }

  expect_failures = [var.cluster_version]
}

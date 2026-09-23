# Native terraform tests (`terraform test`).
#
# The EKS and Karpenter modules are third-party and build their IAM from data
# sources a mocked provider cannot satisfy, so a full mocked plan of this root
# module is not useful — and testing someone else's module is not this repo's job
# anyway. What IS this repo's job is the input contract, which is what these
# assert, using `terraform test`'s ability to check that a validation rejects what
# it is supposed to reject.

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

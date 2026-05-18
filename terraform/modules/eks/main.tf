# MiniStack EKS: API simulation only.
# This creates the EKS control plane record in MiniStack and lets Terraform
# manage the full EKS resource lifecycle (plan/apply/destroy).
# Actual pod scheduling is handled by the kind cluster (Phase 3).
resource "aws_eks_cluster" "main" {
  name     = var.project_name
  version  = var.cluster_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids = var.subnet_ids
  }

  tags = { Project = var.project_name }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = 4
    min_size     = 2
    max_size     = 6
  }

  instance_types = ["t3.medium"]

  tags = { Project = var.project_name }
}

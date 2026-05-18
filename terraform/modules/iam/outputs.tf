output "cluster_role_arn" {
  value = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

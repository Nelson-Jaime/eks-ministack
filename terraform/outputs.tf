output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "ecr_backend_url" {
  description = "ECR backend repository URL (MiniStack)"
  value       = module.ecr_backend.repository_url
}

output "ecr_frontend_url" {
  description = "ECR frontend repository URL (MiniStack)"
  value       = module.ecr_frontend.repository_url
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint (MiniStack mock)"
  value       = module.eks.cluster_endpoint
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = module.route53.zone_id
}

output "route53_zone_name" {
  description = "Route53 hosted zone name"
  value       = module.route53.zone_name
}

provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    ec2     = "http://localhost:4566"
    ecr     = "http://localhost:4566"
    eks     = "http://localhost:4566"
    elb     = "http://localhost:4566"
    elbv2   = "http://localhost:4566"
    iam     = "http://localhost:4566"
    route53 = "http://localhost:4566"
    s3      = "http://localhost:4566"
    sts     = "http://localhost:4566"
  }
}

module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
}

module "ecr" {
  source = "./modules/ecr"

  repository_name = "${var.project_name}/fastapi-app"
}

module "eks" {
  source = "./modules/eks"

  project_name     = var.project_name
  cluster_version  = var.cluster_version
  subnet_ids       = module.vpc.private_subnet_ids
  cluster_role_arn = module.iam.cluster_role_arn
  node_role_arn    = module.iam.node_role_arn
}

module "route53" {
  source = "./modules/route53"

  project_name = var.project_name
}

terraform {
  backend "s3" {
    bucket = "eks-ministack-tfstate"
    key    = "terraform.tfstate"
    region = "us-east-1"

    endpoints = {
      s3 = "http://localhost:4566"
    }

    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}

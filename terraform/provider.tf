terraform {
  required_version = ">= 1.0"
  required_providers {
    arvancloud = {
      source  = "terraform.arvancloud.ir/arvancloud/arvancloud"
      version = "~> 0.4.0"
    }
  }

  # Uncomment and configure once S3 backend is ready
  # backend "s3" {
  #   bucket         = "taban-terraform-state"
  #   key            = "arvan/terraform.tfstate"
  #   region         = "ir-thr-ba1"
  #   endpoint       = "https://s3.arvancloud.ir"
  #   skip_region_validation = true
  # }
}

provider "arvancloud" {
  api_key = var.arvan_api_key
}

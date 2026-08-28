terraform {
  required_version = ">= 1.0"
  required_providers {
    arvancloud = {
      # source confirmed correct (unified, current provider) 2026-08-24 — a
      # separate legacy `.../arvancloud/iaas` provider exists on GitLab,
      # stale since 2026-04-19; don't substitute it. See README.md "Known risks".
      source  = "terraform.arvancloud.ir/arvancloud/arvancloud"
      # this pin is well behind the source-audited v0.6.0 (VPC added at
      # 0.6.0). Bump and re-verify before relying on anything past core IaaS.
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

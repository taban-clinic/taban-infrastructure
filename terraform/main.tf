# Main outputs and data sources

# Get available regions and AZs
data "arvancloud_iaas_regions" "all" {}
data "arvancloud_iaas_availability_zones" "all" {}

# Placeholder outputs
output "provider_version" {
  value       = "See terraform init output"
  description = "Terraform Arvan provider version"
}

output "available_regions" {
  value       = "Run: terraform console && data.arvancloud_iaas_regions.all.regions"
  description = "Available Arvan regions"
}

output "deployment_info" {
  value = {
    datacenter = var.datacenter
    environment = var.environment
    project = var.project_name
  }
  description = "Deployment configuration"
}

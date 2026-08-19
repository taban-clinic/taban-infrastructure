# Arvan Object Storage (S3-compatible)
# For Terraform state, backups, and application uploads

# resource "arvancloud_storage_bucket" "state" {
#   name = "${var.project_name}-terraform-state"
#   region = var.datacenter
#
#   tags = merge(var.tags, {
#     Purpose = "terraform-state"
#   })
# }

# resource "arvancloud_storage_bucket" "backups" {
#   name = "${var.project_name}-backups"
#   region = var.datacenter
#
#   versioning_enabled = true
#   retention_days     = 90
#
#   tags = merge(var.tags, {
#     Purpose = "backups"
#   })
# }

# output "state_bucket" {
#   value = arvancloud_storage_bucket.state.name
#   description = "S3 bucket for Terraform state"
# }

# output "backups_bucket" {
#   value = arvancloud_storage_bucket.backups.name
#   description = "S3 bucket for database/system backups"
# }

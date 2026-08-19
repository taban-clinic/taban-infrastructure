# Managed PostgreSQL on Arvan Cloud
# TODO: Implement once PostgreSQL managed service availability is confirmed

# resource "arvancloud_database" "taban" {
#   name          = "${var.project_name}-postgres"
#   engine        = "postgresql"
#   engine_version = "14"
#   availability_zone = var.datacenter
#
#   # Size configuration
#   # instance_class = "db.g2.small"
#   # storage_size   = 100  # GB
#
#   tags = var.tags
# }

# output "database_host" {
#   value       = arvancloud_database.taban.endpoint
#   description = "PostgreSQL endpoint"
# }

# output "database_port" {
#   value       = arvancloud_database.taban.port
#   description = "PostgreSQL port"
# }

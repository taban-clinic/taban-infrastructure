# Arvan Cloud server resource
# TODO: Implement server creation once machine user API key is verified

# data "arvancloud_iaas_flavors" "available" {
#   availability_zone = var.datacenter
#   category          = "general"
# }

# data "arvancloud_iaas_images" "ubuntu" {}

# data "arvancloud_iaas_ssh_keys" "taban" {}

# resource "arvancloud_iaas_server" "main" {
#   name              = "${var.project_name}-${var.server_name}"
#   flavor_id         = data.arvancloud_iaas_flavors.available.flavors[0].id
#   image_id          = data.arvancloud_iaas_images.ubuntu.images[0].id
#   availability_zone = var.datacenter
#   disk_size         = var.disk_size
#   enable_ipv4       = var.enable_ipv4
#   enable_ipv6       = var.enable_ipv6
#   ha_enabled        = var.ha_enabled
#   enable_backup     = var.enable_backup
#   tags              = var.tags
#
#   # lifecycle {
#   #   ignore_changes = [private_network_ids, volume_attachments]
#   # }
# }

# output "server_ip" {
#   value       = arvancloud_iaas_server.main.public_ip_address
#   description = "Server public IPv4 address"
# }

# Arvan Cloud server resource
# TODO: Implement server creation once machine user API key is verified
#
# WARNING before uncommenting (see README.md "Known risks", 2026-08-24):
# - data.arvancloud_iaas_images below always returns 0 results — GET /images
#   is tenant-private-images-only, never the public catalog. Hardcode a
#   known-good image UUID instead of using this data source's .images[0].id.
# - data.arvancloud_iaas_ssh_keys below hit an IAM permission denial on the
#   aiautobiz account's custom machine-user role; verify against this
#   account's role first, or expect it to fail the same way.

# data "arvancloud_iaas_flavors" "available" {
#   availability_zone = var.datacenter
#   category          = "general"
# }

# data "arvancloud_iaas_images" "ubuntu" {}  # BROKEN — see WARNING above, hardcode image_id instead

# data "arvancloud_iaas_ssh_keys" "taban" {}  # LIKELY BLOCKED BY IAM — see WARNING above

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

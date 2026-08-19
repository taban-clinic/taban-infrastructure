variable "arvan_api_key" {
  description = "Arvan Cloud API key (machine user)"
  type        = string
  sensitive   = true
}

variable "datacenter" {
  description = "Arvan datacenter availability zone"
  type        = string
  default     = "ir-thr-ba1" # Bamdad, West Tehran
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project/business name"
  type        = string
  default     = "taban"
}

variable "server_name" {
  description = "Server hostname"
  type        = string
  default     = "dr-yousefi"
}

variable "server_flavor" {
  description = "Arvan instance flavor (size)"
  type        = string
  default     = "g2-general-1" # Adjust based on capacity needs
}

variable "disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 100
}

variable "enable_backup" {
  description = "Enable weekly automated backups"
  type        = bool
  default     = true
}

variable "enable_ipv4" {
  description = "Enable public IPv4"
  type        = bool
  default     = true
}

variable "enable_ipv6" {
  description = "Enable public IPv6"
  type        = bool
  default     = false
}

variable "ha_enabled" {
  description = "Enable HA mode (auto-restart on failure)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default = {
    Terraform = "true"
    Project   = "taban"
  }
}

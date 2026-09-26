variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network_name" {
  type    = string
  default = "default"
}

variable "firewall_name" {
  type = string
}

variable "firewall_ports" {
  type = list(string)
}

variable "source_ranges" {
  type = list(string)
}

variable "target_tags" {
  type    = list(string)
  default = []
}

variable "address_name" {
  type = string
}

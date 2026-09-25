variable "project_id" {
  type = string
}

variable "name" {
  type = string
}

variable "zone" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "image" {
  type = string
}

variable "disk_size" {
  type    = number
  default = 50
}

variable "disk_type" {
  type    = string
  default = "pd-ssd"
}

variable "resource_policies" {
  type    = list(string)
  default = []
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "nat_ip" {
  type    = string
  default = null
}

variable "service_account_email" {
  type = string
}

variable "service_account_scopes" {
  type    = list(string)
  default = []
}

output "network_id" {
  value = data.google_compute_network.this.id
}

output "external_ip" {
  value = google_compute_address.dev_vm_ip.address
}

output "firewall_name" {
  value = google_compute_firewall.allow_web.name
}

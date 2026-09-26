data "google_compute_network" "this" {
  project = var.project_id
  name    = var.network_name
}

resource "google_compute_firewall" "allow_web" {
  project = var.project_id

  name    = var.firewall_name
  network = data.google_compute_network.this.id

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = var.firewall_ports
  }

  source_ranges = var.source_ranges
  target_tags   = var.target_tags
}

resource "google_compute_address" "dev_vm_ip" {
  project = var.project_id
  region  = var.region

  name = var.address_name
}

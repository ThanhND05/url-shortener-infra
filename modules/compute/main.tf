resource "google_compute_instance" "this" {
  name         = var.name
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type

  tags = var.tags

  key_revocation_action_type = "NONE"

  metadata = {
    enable-osconfig = "TRUE"
  }

  boot_disk {
    auto_delete = true
    device_name = var.name

    initialize_params {
      image             = var.image
      size              = var.disk_size
      type              = var.disk_type
      resource_policies = var.resource_policies
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork

    access_config {
      nat_ip       = var.nat_ip
      network_tier = "PREMIUM"
    }
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  service_account {
    email  = var.service_account_email
    scopes = var.service_account_scopes
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"]
    ]
  }
}

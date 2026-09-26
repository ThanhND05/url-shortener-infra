module "compute" {
  source = "../../modules/compute"

  project_id   = var.project_id
  name         = "devops-lab"
  zone         = var.zone
  machine_type = "e2-standard-2"

  tags = [
    "http-server",
    "https-server"
  ]

  image = "https://www.googleapis.com/compute/v1/projects/ubuntu-os-cloud/global/images/ubuntu-minimal-2404-noble-amd64-v20260904"

  disk_size = 50
  disk_type = "pd-ssd"

  resource_policies = [
    "https://www.googleapis.com/compute/v1/projects/urlshortener-509008/regions/asia-southeast1/resourcePolicies/default-schedule-1"
  ]

  network = "https://www.googleapis.com/compute/v1/projects/urlshortener-509008/global/networks/default"

  subnetwork = "https://www.googleapis.com/compute/v1/projects/urlshortener-509008/regions/asia-southeast1/subnetworks/default"

  nat_ip = "34.177.96.199"

  service_account_email = "891220966069-compute@developer.gserviceaccount.com"

  service_account_scopes = [
    "https://www.googleapis.com/auth/devstorage.read_only",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring.write",
    "https://www.googleapis.com/auth/service.management.readonly",
    "https://www.googleapis.com/auth/servicecontrol",
    "https://www.googleapis.com/auth/trace.append"
  ]
}


module "networking" {
  source = "../../modules/networking"

  project_id   = var.project_id
  region       = var.region
  network_name = "default"

  firewall_name = "allow-web"

  firewall_ports = [
    "80",
    "443",
    "3000",
    "5173",
    "9090",
    "8080",
    "8081",
    "8082"
  ]

  source_ranges = [
    "0.0.0.0/0"
  ]

  target_tags = [
    "http-server"
  ]

  address_name = "devops-lab"
}

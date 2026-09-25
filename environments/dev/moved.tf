moved {
  from = google_compute_instance.devops_lab
  to   = module.compute.google_compute_instance.this
}

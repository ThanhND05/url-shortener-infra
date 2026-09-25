output "vm_name" {
  value = module.compute.instance_name
}

output "vm_external_ip" {
  value = module.compute.external_ip
}

output "vm_internal_ip" {
  value = module.compute.internal_ip
}

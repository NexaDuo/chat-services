output "vm_public_ip" {
  value = module.vm.public_ip
}

output "tunnel_token" {
  value     = module.tunnel.tunnel_token
  sensitive = true
}

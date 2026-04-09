output "project_info" {
  description = "Project information"
  value = {
    name        = local.project_name
    environment = local.environment
    status      = "Phase 1: Ansible-based configuration (single Pi)"
    next_phase  = "Phase 2: Terraform provisioning"
  }
}

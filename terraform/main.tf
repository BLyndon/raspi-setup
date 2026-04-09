terraform {
  required_version = ">= 1.4"
}

locals {
  project_name = "raspi-setup"
  environment  = "prod"
  tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "Terraform"
    CreatedAt   = timestamp()
  }
}

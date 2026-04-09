# Terraform variables for Raspberry Pi setup
# Override in terraform.tfvars or use -var flag
# Example: terraform apply -var="pi_hostname=my-pi"

variable "pi_hostname" {
  description = "Hostname for the Raspberry Pi"
  type        = string
  default     = "raspi-01"
}

variable "pi_model" {
  description = "Raspberry Pi model (3b, 4b, 5, zero2, etc.)"
  type        = string
  default     = "5"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "project_name" {
  description = "Project name for tagging and identification"
  type        = string
  default     = "raspi-setup"
}

# ── SSH and Ollama deployment ────────────────────────────────────────────────

variable "pi_host" {
  description = "IP address or hostname of the Raspberry Pi for SSH connection"
  type        = string
  default     = "192.168.1.100"

  validation {
    condition     = length(trimspace(var.pi_host)) > 0
    error_message = "pi_host must not be empty."
  }
}

variable "pi_ssh_user" {
  description = "SSH user for connecting to the Raspberry Pi"
  type        = string
  default     = "pi"
}

variable "pi_ssh_key_path" {
  description = "Path to the SSH private key for connecting to the Raspberry Pi"
  type        = string
  default     = "~/.ssh/id_ed25519"

  validation {
    condition     = length(trimspace(var.pi_ssh_key_path)) > 0
    error_message = "pi_ssh_key_path must not be empty."
  }
}

variable "enable_ollama" {
  description = "Deploy Ollama on the Raspberry Pi"
  type        = bool
  default     = true
}

variable "ollama_port" {
  description = "Host port to expose Ollama API on"
  type        = number
  default     = 11434

  validation {
    condition     = var.ollama_port >= 1 && var.ollama_port <= 65535
    error_message = "ollama_port must be between 1 and 65535."
  }
}

variable "ollama_model" {
  description = "Ollama model to pre-pull after installation"
  type        = string
  default     = "gemma4:e2b"

  validation {
    condition     = length(trimspace(var.ollama_model)) > 0
    error_message = "ollama_model must not be empty."
  }
}

variable "ollama_allowed_cidr" {
  description = "CIDR allowed to access Ollama when UFW is installed"
  type        = string
  default     = "192.168.1.0/24"

  validation {
    condition     = can(cidrhost(var.ollama_allowed_cidr, 1))
    error_message = "ollama_allowed_cidr must be a valid CIDR block, e.g. 192.168.1.0/24."
  }
}

variable "enable_open_webui" {
  description = "Deploy Open WebUI on the Raspberry Pi"
  type        = bool
  default     = false
}

variable "open_webui_port" {
  description = "Host port to expose Open WebUI on"
  type        = number
  default     = 3000

  validation {
    condition     = var.open_webui_port >= 1 && var.open_webui_port <= 65535
    error_message = "open_webui_port must be between 1 and 65535."
  }
}

variable "ollama_url" {
  description = "Ollama API URL used by Open WebUI"
  type        = string
  default     = "http://host.docker.internal:11434"

  validation {
    condition     = can(regex("^https?://", var.ollama_url))
    error_message = "ollama_url must start with http:// or https://."
  }
}

variable "open_webui_image_tag" {
  description = "Open WebUI Docker image tag"
  type        = string
  default     = "main"

  validation {
    condition     = length(trimspace(var.open_webui_image_tag)) > 0
    error_message = "open_webui_image_tag must not be empty."
  }
}

# ── Ollama ───────────────────────────────────────────────────────────────────
# Installs Ollama natively via the upstream install script, configures the
# systemd service, and pre-pulls a model.

resource "terraform_data" "ollama" {
  count = var.enable_ollama ? 1 : 0

  triggers_replace = {
    host          = var.pi_host
    port          = var.ollama_port
    model         = var.ollama_model
    firewall_cidr = var.ollama_allowed_cidr
  }

  connection {
    type        = "ssh"
    host        = var.pi_host
    user        = var.pi_ssh_user
    private_key = file(pathexpand(var.pi_ssh_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      # Check prerequisites and install dependencies
      "sudo apt-get update -y",
      "sudo apt-get install -y curl",

      # Install Ollama with retries using the upstream installer
      "installed=0; for i in 1 2 3 4 5; do bash -lc 'set -o pipefail; curl -fsSL https://ollama.com/install.sh | sh' && installed=1 && break; echo 'ollama install failed, retrying in 10s...'; sleep 10; done; [ \"$installed\" -eq 1 ]",
      "ollama --version",

      # Configure Ollama to listen on the host interface
      "sudo mkdir -p /etc/systemd/system/ollama.service.d",
      "printf '[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0:${var.ollama_port}\"\n' | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now ollama",
      "sudo systemctl restart ollama",

      # Restrict LAN access to Ollama via UFW
      "if command -v ufw >/dev/null 2>&1; then sudo ufw allow from ${var.ollama_allowed_cidr} to any port ${var.ollama_port} proto tcp; fi",

      # Wait for Ollama, then pull and verify the requested model
      "for i in 1 2 3 4 5; do sudo systemctl is-active --quiet ollama && break; sleep 2; done; sudo systemctl is-active --quiet ollama",
      "OLLAMA_HOST=http://127.0.0.1:${var.ollama_port} ollama pull ${var.ollama_model}",
      "OLLAMA_HOST=http://127.0.0.1:${var.ollama_port} ollama list | grep -Fq '${var.ollama_model}'",
    ]
  }
}

output "ollama_service_url" {
  description = "URL to access Ollama API"
  value       = var.enable_ollama ? "http://${var.pi_host}:${var.ollama_port}" : null
}

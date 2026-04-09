# ── Open WebUI ───────────────────────────────────────────────────────────────
# Deploys Open WebUI in Docker to avoid host Python compatibility issues.

resource "terraform_data" "open_webui" {
  count = var.enable_open_webui ? 1 : 0

  depends_on = [terraform_data.ollama]

  triggers_replace = {
    host        = var.pi_host
    port        = var.open_webui_port
    ollama_url  = var.ollama_url
    ollama_port = var.ollama_port
    image_tag   = var.open_webui_image_tag
  }

  connection {
    type        = "ssh"
    host        = var.pi_host
    user        = var.pi_ssh_user
    private_key = file(pathexpand(var.pi_ssh_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      # Ensure Docker is installed and running
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io",
      "sudo systemctl enable --now docker",

      # Pull latest Open WebUI image with retries for flaky networks
      "pulled=0; for i in 1 2 3 4 5; do sudo docker pull ghcr.io/open-webui/open-webui:${var.open_webui_image_tag} && pulled=1 && break; echo 'docker pull failed, retrying in 10s...'; sleep 10; done; [ \"$pulled\" -eq 1 ]",

      # Replace running container (idempotent)
      "sudo docker stop open-webui 2>/dev/null || true",
      "sudo docker rm open-webui 2>/dev/null || true",
      "sudo docker volume create open-webui-data >/dev/null",
      "sudo docker run -d --name open-webui --restart unless-stopped --add-host=host.docker.internal:host-gateway -p ${var.open_webui_port}:8080 -v open-webui-data:/app/backend/data -e OLLAMA_BASE_URL=${var.ollama_url} ghcr.io/open-webui/open-webui:${var.open_webui_image_tag}",
      "for i in 1 2 3 4 5 6 7 8 9 10; do curl -fsS http://127.0.0.1:${var.open_webui_port}/ >/dev/null && break; sleep 3; done; curl -fsS http://127.0.0.1:${var.open_webui_port}/ >/dev/null",
    ]
  }
}

output "open_webui_url" {
  description = "URL to access Open WebUI"
  value       = var.enable_open_webui ? "http://${var.pi_host}:${var.open_webui_port}" : null
}

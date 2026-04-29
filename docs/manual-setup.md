# Manual Setup Guide

This guide walks through every step that `setup.sh` automates, for those who prefer to understand and run each command themselves.

---

## 1. Create a DigitalOcean Droplet

- **OS:** Ubuntu 22.04 or 24.04 LTS
- **Size:** Minimum 2 GB RAM / 1 vCPU. 4 GB RAM recommended for heavier use.
- **Region:** Wherever is closest to your users.
- **Optional:** Add your SSH key during creation for passwordless login.

Once the Droplet is created, note its public IP address.

---

## 2. Point your domain at the Droplet (optional)

A domain name is not required. You have two options:

**Option A — No domain (quickest)**
Leave `DOMAIN` set to your Droplet's bare IP address in `.env`. `setup.sh` will automatically convert it to a free [sslip.io](https://sslip.io) subdomain (e.g. `1.2.3.4` becomes `1-2-3-4.sslip.io`). Caddy obtains a trusted Let's Encrypt certificate for that subdomain with no DNS configuration on your part.

**Option B — Custom domain**
Create an **A record** in your DNS provider:

| Field  | Value                          |
|--------|--------------------------------|
| Name   | `langflow` (or `@` for root)   |
| Type   | `A`                            |
| Value  | Your Droplet's public IP       |
| TTL    | 3600 (or your provider's default) |

DNS propagation can take a few minutes to a few hours. Caddy will not obtain a certificate until the domain resolves to this server.

---

## 3. SSH into the Droplet

```bash
ssh root@<your-droplet-ip>
```

---

## 4. Install Docker

```bash
# Update packages and install prerequisites
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker's apt repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

# Install Docker and the Compose plugin
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker
systemctl enable --now docker
```

Verify it worked:

```bash
docker --version
docker compose version
```

---

## 5. Configure the firewall

```bash
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP'
ufw allow 443/tcp  comment 'HTTPS'
ufw --force enable
ufw status
```

---

## 6. Clone the repository

```bash
git clone https://github.com/paul-byford/langflow-digitalocean.git
cd langflow-digitalocean
```

---

## 7. Configure `.env`

```bash
cp .env.example .env
nano .env
```

Fill in your values:

| Variable                     | Description                              |
|------------------------------|------------------------------------------|
| `DOMAIN`                     | Domain name or bare IP. A bare IP is auto-converted to `x-x-x-x.sslip.io` by `setup.sh`. |
| `LANGFLOW_SUPERUSER`         | Langflow admin username                  |
| `LANGFLOW_SUPERUSER_PASSWORD`| Langflow admin password                  |
| `POSTGRES_USER`              | PostgreSQL username                      |
| `POSTGRES_PASSWORD`          | PostgreSQL password                      |
| `POSTGRES_DB`                | PostgreSQL database name                 |
| `LANGFLOW_VERSION`           | Langflow image tag (default: `latest`)   |

---

## 8. Start the services

```bash
docker compose pull
docker compose up -d
```

This pulls the images (may take a minute or two) and starts three containers: `db`, `langflow`, and `caddy`.

---

## 9. Verify services are healthy

```bash
docker compose ps
```

You should see all three services with a status of `healthy` or `running`. You can also tail the logs:

```bash
docker compose logs -f
```

Langflow takes about 60 seconds to initialise on first start. Watch for a line like `Application startup complete`.

---

## 10. Access Langflow

Open a browser and navigate to:

```
https://<your-domain>
```

Caddy obtains the HTTPS certificate automatically on the first request. Log in with the `LANGFLOW_SUPERUSER` credentials you set in `.env`.

---

## Troubleshooting

**Certificate not issued yet**
Caddy needs port 80 reachable from the internet and the domain must resolve to this server's IP. Check DNS propagation with `dig +short <your-domain>` and confirm UFW allows port 80.

**Langflow container keeps restarting**
Check the logs: `docker compose logs langflow`. A common cause is the database not being ready; the health check on the `db` service should prevent this, but on very slow machines the `start_period` may need increasing in `docker-compose.yml`.

**Cannot connect on port 80 or 443**
Confirm UFW rules with `ufw status` and verify DigitalOcean's cloud firewall (if enabled in the control panel) also allows those ports.

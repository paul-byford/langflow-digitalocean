# langflow-digitalocean

Deploy Langflow on DigitalOcean with automatic HTTPS in under 10 minutes.

---

## What you get

- Langflow behind [Caddy](https://caddyserver.com/) with automatic TLS — no Certbot, no cron jobs
- PostgreSQL persistence via a named Docker volume
- All configuration in a single `.env` file
- One-command setup via `setup.sh` (Linux/macOS) or `setup.ps1` (Windows)

---

## Prerequisites

- A DigitalOcean Droplet running Ubuntu 22.04 or 24.04 (minimum 2 GB RAM / 1 vCPU — 4 GB recommended for heavier use)
- An SSH key pair on your local machine (see below)
- A domain name is **optional**. You can use the Droplet's bare IP address; the setup script converts it to a free [sslip.io](https://sslip.io) subdomain so you still get a trusted HTTPS certificate with no DNS configuration.

---

## SSH key setup

### Do you already have a key?

**Windows** — open PowerShell and run:

```powershell
Test-Path "$env:USERPROFILE\.ssh\id_ed25519"
```

**Linux / macOS:**

```bash
ls ~/.ssh/id_ed25519
```

If the file exists you already have a key and can skip to the next step.

### Generate a new key (if you don't have one)

**Windows** (PowerShell), **Linux**, and **macOS** all ship with OpenSSH. Run:

```bash
ssh-keygen -t ed25519
```

Accept the default path and set a passphrase when prompted. This creates two files:

| File | Purpose |
|------|---------|
| `id_ed25519` | Private key — keep this secret, never share it |
| `id_ed25519.pub` | Public key — this is what you give to servers |

On Windows these files are saved to `C:\Users\<your-username>\.ssh\`.

### Add your public key to DigitalOcean

**When creating the Droplet:** in the *Authentication* section choose **SSH Key**, click **New SSH Key**, and paste the contents of your `id_ed25519.pub` file.

To print the public key so you can copy it:

```powershell
# Windows
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

```bash
# Linux / macOS
cat ~/.ssh/id_ed25519.pub
```

If you already have a Droplet without your key added, you can add it retroactively via **Settings > Security > SSH Keys** in the DigitalOcean control panel, then copy it to the Droplet with `ssh-copy-id`.

> **Important:** `setup.ps1` connects to the Droplet using your SSH key. If the key was not added to the Droplet at creation time the script will fail at the connection step.

---

## Quick start

**Linux / macOS** (run directly on the Droplet):

```bash
git clone https://github.com/paul-byford/langflow-digitalocean.git
cd langflow-digitalocean
cp .env.example .env
# Edit .env with your domain and credentials
nano .env
sudo bash setup.sh
```

**Windows** (run from your local machine -- no WSL required):

```powershell
git clone https://github.com/paul-byford/langflow-digitalocean.git
cd langflow-digitalocean
copy .env.example .env
# Edit .env with your domain and credentials
notepad .env
.\setup.ps1
```

`setup.ps1` uses the built-in Windows OpenSSH client to copy the project to your Droplet and run `setup.sh` remotely. It will prompt for your Droplet IP, SSH user, and key path.

Caddy obtains an HTTPS certificate automatically once DNS resolves.

---

## Configuration reference

| Variable                      | Description                                      | Default                  |
|-------------------------------|--------------------------------------------------|--------------------------|
| `DOMAIN`                      | Domain name or bare server IP address            | `langflow.example.com`   |
| `LANGFLOW_SUPERUSER`          | Langflow admin username                          | `admin`                  |
| `LANGFLOW_SUPERUSER_PASSWORD` | Langflow admin password                          | `generated`              |
| `POSTGRES_USER`               | PostgreSQL username                              | `langflow`               |
| `POSTGRES_PASSWORD`           | PostgreSQL password                              | `generated`              |
| `POSTGRES_DB`                 | PostgreSQL database name                         | `langflow`               |
| `LANGFLOW_VERSION`            | Langflow image tag to use                        | `latest`                 |

---

## Manual setup

Prefer to understand each step rather than run a script? See [docs/manual-setup.md](docs/manual-setup.md) for a full walkthrough.

---

## Updating Langflow

Pull the latest image and recreate the container:

```bash
docker compose pull
docker compose up -d
```

Your data is stored in the `pgdata` volume and will not be affected.

---

## Backup and restore

**Backup:**

```bash
docker exec langflow-digitalocean-db-1 \
  pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" \
  > backup_$(date +%Y%m%d_%H%M%S).sql
```

**Restore:**

```bash
docker exec -i langflow-digitalocean-db-1 \
  psql -U "${POSTGRES_USER}" "${POSTGRES_DB}" \
  < backup_<timestamp>.sql
```

Replace `langflow-digitalocean-db-1` with the actual container name shown by `docker compose ps` if it differs.

---

## Troubleshooting

**Browser shows a security warning**
If you deployed with a bare IP address, Caddy uses a self-signed certificate. Click Advanced and proceed to accept it. To get a trusted certificate, point a domain at the server, update `DOMAIN` in `.env`, and re-run the setup script.

**HTTPS certificate not being issued (domain deployments)**
Caddy needs port 80 reachable from the internet and your domain must resolve to this server's IP. Check with `dig +short <your-domain>` and confirm UFW allows port 80. Certificate issuance can take a minute or two after DNS propagates.

**Port 80 or 443 not reachable**
Run `ufw status` and confirm both ports are allowed. If you have a DigitalOcean cloud firewall enabled in the control panel, ensure it also allows those ports.

**Langflow health check failing**
Langflow takes around 60 seconds to initialise on first start. Check logs with `docker compose logs -f langflow`. If the database connection is failing, verify your `POSTGRES_*` variables in `.env` match between the `langflow` and `db` services.

**DNS not propagated yet**
Use a tool like [dnschecker.org](https://dnschecker.org) to verify your A record is live globally before running setup.

---

## Licence

MIT — see [LICENSE](LICENSE).

# Taban Infrastructure — Arvan Cloud Provisioning

Infrastructure-as-code for Taban Dental Clinic, Iran Implant Rescue Institute, and Dr-yousefi.ir hosted on Arvan Cloud.

## Quick Start

### 1. Setup credentials

```bash
# Activate direnv
direnv allow .

# Edit .envrc and add your Arvan API key
export ARVAN_API_KEY="your-machine-user-api-key"
```

### 2. Verify server readiness

Before provisioning, check that the server is accessible and healthy from your machine:

```bash
# Start SOCKS proxy in one terminal
ssh -N -D 127.0.0.1:1080 ubuntu@185.206.93.107

# In another terminal, run server checks
cd ansible
ansible-playbook -i inventory.ini playbooks/server-checks.yml
```

This will verify:
- ✓ Network connectivity (DNS, gateway, external IPs)
- ✓ Disk/memory/CPU availability
- ✓ Package manager access (apt)
- ✓ SSH key authentication
- ✓ Critical tools (Python, curl, git)

### 3. Plan infrastructure

```bash
cd terraform
terraform init
terraform plan
```

### 4. Apply infrastructure

```bash
terraform apply
```

## Directory Structure

```
taban-infrastructure/
├── .envrc                   # Credentials & environment (never commit secrets)
├── .sid-identity            # GitHub identity for this repo
├── README.md
├── ansible/
│   ├── inventory.ini        # Server inventory (SOCKS proxy config)
│   └── playbooks/
│       ├── server-checks.yml    # Readiness verification (run first)
│       ├── base.yml             # Base OS setup (users, SSH, Docker, Caddy)
│       └── apps.yml             # Application deployments
└── terraform/
    ├── provider.tf          # Arvan provider + auth
    ├── variables.tf         # Input variables
    ├── server.tf            # EC2-like server resource
    ├── database.tf          # Managed PostgreSQL
    ├── storage.tf           # Object Storage
    ├── main.tf              # Outputs
    └── terraform.tfvars     # Values (in .gitignore)
```

## Prerequisites

- **Local machine:** `direnv`, Ansible 2.10+, Terraform 1.0+, `netcat` (nc)
- **SSH key:** `~/.ssh/id_ed25519_taban` (ed25519 format)
- **Jump host:** Access to 185.206.93.107 (SOCKS proxy)
- **Arvan Cloud:** Machine user API key with infrastructure permissions

## Server Details

- **IP:** 94.101.177.69 (dr-yousefi.ir)
- **Jump host:** 185.206.93.107 (SOCKS proxy on :1080)
- **OS:** Ubuntu 24.04 LTS
- **SSH:** Key-based auth only (password auth disabled)

## Network Setup

The server is behind Iran's network restrictions. Access via SOCKS proxy:

```bash
# Terminal 1: Proxy
ssh -N -D 127.0.0.1:1080 ubuntu@185.206.93.107

# Terminal 2: SSH to server (automatic via Ansible)
ansible all -i ansible/inventory.ini -m ping
```

Ansible inventory is pre-configured with ProxyCommand — no manual setup needed.

## Workflow

1. **Server readiness** → `ansible-playbook playbooks/server-checks.yml`
2. **Base OS setup** → `ansible-playbook playbooks/base.yml`
3. **Infrastructure** → `terraform plan && terraform apply`
4. **Applications** → `ansible-playbook playbooks/apps.yml`

## Troubleshooting

### SSH timeout
- Verify SOCKS proxy is running: `netstat -ln | grep 1080`
- Check jump host access: `ssh ubuntu@185.206.93.107`
- Verify key path in `.envrc`

### Package manager fails
- May need to set proxy. Add to `.envrc`:
  ```bash
  export HTTP_PROXY="http://proxy.example.com:8080"
  ```
- Or use Iranian mirrors (commented in base playbook)

### Ansible hangs on Gather Facts
- Network latency through proxy is normal (10–30s)
- Increase timeout: `ansible_connection_timeout=60`

## Identity

This repo uses GitHub identity: `tabandentalclinic0-dev`

Set once, trust the hook:
```bash
direnv allow .
```

## References

- [Arvan Cloud Provisioning Guide](../allinone-roadmap/docs/arvan-provisioning-guide.md)
- [SSH Hardening Runbook](../allinone-roadmap/docs/runbook-ssh-hardening.md)
- [Terraform Arvan Provider](https://git.arvancloud.ir/arvancloud/terraform-provider-arvancloud)

# intersight-terraform

Terraform configuration to deploy a Cisco Intersight Virtual Appliance on OpenStack with basic default settings.

---

## Prerequisites

- Terraform >= 1.3
- Intersight Virtual Appliance image imported into OpenStack
- OpenStack application credential in `clouds.yaml`
- Minimum compute: 8 vCPU / 32GB RAM / 500GB disk

---

## Importing the Intersight Appliance Image

Download the Intersight Virtual Appliance OVA from [Cisco Software Download](https://software.cisco.com) and import it into OpenStack:

```bash
openstack image create "intersight-appliance" \
  --file intersight-appliance.qcow2 \
  --disk-format qcow2 \
  --container-format bare \
  --public
```

---

## Authentication

Set up OpenStack credentials via `clouds.yaml` and export environment variables:

```bash
source setup_env.sh ~/.config/openstack/clouds.yaml openstack
```

---

## Configuration

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values. Required fields:

| Variable | Description |
|---|---|
| `management_network` | OpenStack network for the appliance |
| `admin_password` | Initial admin password for the web UI |
| `image_name` | Intersight image name in OpenStack |

### Proxy

If your environment requires a proxy for the appliance to reach Cisco cloud (licensing, updates):

```hcl
proxy_host = "proxy.yourdomain.com"
proxy_port = 3128
```

Leave `proxy_host` empty to disable proxy configuration.

---

## Deploy

### Automated (recommended)

`deploy.sh` downloads the latest Intersight VA image from Cisco Software Central, uploads it to OpenStack, then runs `terraform apply` — all in one step.

**Requirements:**

1. Cisco API credentials from [apiconsole.cisco.com](https://apiconsole.cisco.com)
2. OpenStack environment loaded via `setup_env.sh`

```bash
# Set Cisco API credentials
export CISCO_CLIENT_ID=your-client-id
export CISCO_CLIENT_SECRET=your-client-secret

# Load OpenStack auth
source setup_env.sh ~/.config/openstack/clouds.yaml openstack

# Run full deploy
bash deploy.sh
```

The script will:
1. Authenticate with Cisco Software Central
2. Find the latest Intersight VA release (qcow2 preferred, OVA fallback)
3. Skip download if image already exists in OpenStack
4. Convert OVA → qcow2 if needed (requires `qemu-img`: `brew install qemu`)
5. Upload image to OpenStack
6. Run `terraform apply`

### Manual

```bash
terraform init
terraform plan
terraform apply
```

---

## Accessing the Appliance

The appliance URL is printed in the Terraform output:

```
Outputs:

appliance_url  = "https://203.0.113.10"
management_ip  = "10.0.0.10"
```

Open the URL in a browser and log in with:
- **Username:** `admin`
- **Password:** value of `admin_password` in your `terraform.tfvars`

> Allow 10-15 minutes for the appliance to fully initialise after deployment.

---

## Ports Required

| Port | Direction | Purpose |
|------|-----------|---------|
| 443 | Inbound | Web UI / API access |
| 80 | Inbound | HTTP redirect to HTTPS |
| 22 | Inbound | SSH management |
| 443 | Outbound | Cisco cloud connectivity (licensing, updates) |

---

## Destroy

```bash
terraform destroy
```

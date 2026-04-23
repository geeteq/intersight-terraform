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

Download the Intersight Virtual Appliance from [Cisco Software Download](https://software.cisco.com) and import it into OpenStack:

```bash
openstack image create "intersight-appliance" \
  --file intersight-appliance.qcow2 \
  --disk-format qcow2 \
  --container-format bare \
  --private
```

Or use `deploy.sh` (see [Deploy](#deploy)) to handle the upload automatically.

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

`deploy.sh` handles image upload to OpenStack (if not already present) and runs `terraform apply` in one step. It supports two modes:

**Option A — Local image file (no Cisco API required):**

```bash
export IMAGE_FILE=/path/to/intersight-appliance.tar

source setup_env.sh ~/.config/openstack/clouds.yaml openstack
bash deploy.sh
```

Supported formats: `.tar`, `.tar.gz`, `.tgz`, `.qcow2`, `.vmdk`. The script extracts tar archives automatically and converts vmdk → qcow2 if needed (requires `qemu-img`: `brew install qemu`).

**Option B — Auto-download from Cisco Software Central:**

```bash
export CISCO_CLIENT_ID=your-client-id
export CISCO_CLIENT_SECRET=your-client-secret

source setup_env.sh ~/.config/openstack/clouds.yaml openstack
bash deploy.sh
```

API credentials: [apiconsole.cisco.com](https://apiconsole.cisco.com)

The script will:
1. Check if the image already exists in OpenStack (skips upload if so)
2. Download the latest Intersight VA release from Cisco (qcow2 preferred, OVA fallback)
3. Convert OVA → qcow2 if needed
4. Upload image to OpenStack
5. Run `terraform apply`

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

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

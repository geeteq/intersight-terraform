# intersight-terraform

Terraform configuration to deploy a Cisco Intersight Virtual Appliance on OpenStack.

The Intersight VA KVM package ships as a tar archive containing 8 qcow2 disk images. `deploy.sh` uploads each disk to OpenStack Glance, then Terraform creates Cinder volumes from those images and boots the instance with all 8 disks attached over SCSI.

---

## Prerequisites

- Terraform >= 1.3
- Python 3 with `pip install openstacksdk requests python-openstackclient`
- OpenStack environment loaded via `clouds.yaml`
- Minimum flavor: 8 vCPU / 32 GB RAM
- Cinder quota sufficient for 8 volumes (default 500 GB each = 4 TB total)

---

## Authentication

Load OpenStack credentials before running any commands:

```bash
source setup_env.sh ~/.config/openstack/clouds.yaml openstack
```

---

## Configuration

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Required fields:

| Variable | Description |
|---|---|
| `management_network` | OpenStack network for the appliance management interface |
| `admin_password` | Initial admin password for the web UI |
| `image_name` | Base name for disk images in Glance (e.g. `intersight-appliance`) |
| `availability_zone` | OpenStack availability zone (e.g. `nova`) |

Disk images are uploaded as `{image_name}-1` through `{image_name}-8` and volumes are named `{hostname}-disk-1` through `{hostname}-disk-8`.

### Disk sizes

```hcl
disk_count = 8
disk_sizes = [500, 500, 500, 500, 500, 500, 500, 500]  # GB per disk
```

Adjust `disk_sizes` to match or exceed the virtual size of each qcow2 image. Disk order follows the numerical order of the source files (`disk1.qcow` → disk 1, etc.).

### Proxy

If the appliance needs a proxy to reach Cisco cloud for licensing and updates:

```hcl
proxy_host = "proxy.yourdomain.com"
proxy_port = 3128
```

Leave `proxy_host` empty to disable.

---

## Deploy

### Automated (recommended)

`deploy.sh` uploads disk images to OpenStack Glance and runs `terraform apply` in one step.

**Option A — Local tar file (no Cisco API required):**

```bash
export IMAGE_FILE=/path/to/intersight-appliance-installer-kvm-x.x.x.tar

source setup_env.sh ~/.config/openstack/clouds.yaml openstack
bash deploy.sh
```

The script extracts the tar, finds all `.qcow` disk files in numerical order, and uploads each one. Already-uploaded disks are skipped; incomplete or undersized images are deleted and re-uploaded.

**Option B — Auto-download from Cisco Software Central:**

```bash
export CISCO_CLIENT_ID=your-client-id
export CISCO_CLIENT_SECRET=your-client-secret

source setup_env.sh ~/.config/openstack/clouds.yaml openstack
bash deploy.sh
```

Register for API credentials at [apiconsole.cisco.com](https://apiconsole.cisco.com).

**What the script does:**

1. Extracts the tar and finds all disk images sorted numerically
2. Checks which disk images are already in Glance (skips valid ones)
3. Uploads missing disks as `{image_name}-1` … `{image_name}-8`
4. Runs `terraform apply`

Terraform then:

1. Looks up each Glance image by name
2. Creates 8 Cinder volumes from those images (visible via `openstack volume list`)
3. Boots the instance with all 8 volumes attached in order as SCSI disks

### Manual

```bash
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Glance images must already be uploaded before running Terraform manually.

---

## Accessing the Appliance

Terraform prints the appliance URL on completion:

```
Outputs:

appliance_url  = "https://203.0.113.10"
management_ip  = "10.0.0.10"
```

Log in with:
- **Username:** `admin`
- **Password:** value of `admin_password` in `terraform.tfvars`

> Allow 10–15 minutes for the appliance to fully initialise after first boot.

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
terraform destroy -var-file=terraform.tfvars
```

This destroys the instance and all 8 Cinder volumes.

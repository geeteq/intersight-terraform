# intersight-terraform

Deploys a Cisco Intersight Virtual Appliance on OpenStack using the OpenStack CLI. No Terraform required.

The Intersight VA KVM package ships as a tar archive containing 8 qcow2 disk images. `deploy.sh` uploads each disk to Glance, creates Cinder volumes, and boots the instance — all in one step.

---

## Prerequisites

- Python 3 with `pip install python-openstackclient openstacksdk requests`
- OpenStack environment loaded via `clouds.yaml`
- Minimum flavor: 8 vCPU / 32 GB RAM
- Cinder quota sufficient for 8 volumes (sized automatically from image virtual sizes)

---

## Setup

```bash
source setup_env.sh ~/.config/openstack/clouds.yaml openstack
cp appliance.conf.example appliance.conf
```

Edit `appliance.conf`. Required fields:

| Variable | Description |
|---|---|
| `VM_HOSTNAME` | Name for the VM instance |
| `ADMIN_PASSWORD` | Initial admin password for the web UI |
| `MANAGEMENT_NETWORK` | OpenStack network name |
| `FLAVOR` | Compute flavor (min 8 vCPU / 32 GB RAM) |

---

## Deploy

**From a local tar file (recommended):**

```bash
IMAGE_FILE=/path/to/intersight-appliance-installer-kvm-x.x.x.tar bash deploy.sh
```

**Auto-download from Cisco Software Central:**

```bash
export CISCO_CLIENT_ID=your-client-id
export CISCO_CLIENT_SECRET=your-client-secret
bash deploy.sh
```

The script will:

1. Remove any existing instance and volumes (images in Glance are preserved)
2. Extract the tar and find all `.qcow` disk images sorted numerically
3. Upload missing disks to Glance as `{IMAGE_NAME}-1` … `{IMAGE_NAME}-8` (skips already-uploaded)
4. Read virtual sizes from Glance to size volumes correctly
5. Create security group (if it doesn't exist)
6. Create 8 Cinder volumes from the images and wait for them to be ready
7. Boot the instance with all volumes attached over SCSI
8. Assign a floating IP (if `FLOATING_IP_POOL` is set)

---

## Accessing the Appliance

The URL is printed on completion:

```
  Access:    https://10.0.0.10
  Username:  admin
  Password:  (set in appliance.conf)
```

Allow 10–15 minutes for the appliance to fully initialise after first boot.

---

## Ports Required

| Port | Direction | Purpose |
|------|-----------|---------|
| 443 | Inbound | Web UI / API |
| 80 | Inbound | HTTP redirect |
| 22 | Inbound | SSH |
| 443 | Outbound | Cisco cloud (licensing, updates) |

---

## Cleanup

```bash
openstack server delete intersight-appliance --wait
openstack volume list --name "intersight-appliance-disk-%" -f value -c ID | xargs openstack volume delete
```

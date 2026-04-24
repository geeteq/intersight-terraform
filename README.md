# intersight-deploy

Deploys a Cisco Intersight Virtual Appliance on OpenStack using the OpenStack CLI. No Terraform required.

The Intersight VA KVM package ships as a tar archive containing 8 qcow2 disk images. `deploy.sh` handles everything: uploading disks to Glance, creating Cinder volumes, and booting the instance.

---

## Prerequisites

- Python 3 with `pip install python-openstackclient openstacksdk requests`
- OpenStack credentials loaded (see [Authentication](#authentication))
- Flavor with minimum 8 vCPU / 32 GB RAM
- Cinder quota for 8 volumes — sizes are read automatically from the image virtual sizes

---

## Authentication

```bash
source setup_env.sh ~/.config/openstack/clouds.yaml openstack
```

---

## Configuration

```bash
cp appliance.conf.example appliance.conf
```

Edit `appliance.conf`:

| Variable | Required | Description |
|---|---|---|
| `VM_HOSTNAME` | Yes | VM instance name |
| `ADMIN_PASSWORD` | Yes | Initial admin password for the web UI |
| `MANAGEMENT_NETWORK` | Yes | OpenStack network name |
| `FLAVOR` | Yes | Compute flavor (min 8 vCPU / 32 GB RAM) |
| `AVAILABILITY_ZONE` | No | OpenStack AZ (default: `nova`) |
| `IMAGE_NAME` | No | Glance image base name (default: `intersight-appliance`) |
| `SECURITY_GROUP_NAME` | No | Security group name (default: `intersight-sg`) |
| `FLOATING_IP_POOL` | No | External network for floating IP — leave empty to skip |
| `DNS_SERVERS` | No | Comma-separated DNS servers (default: `8.8.8.8,8.8.4.4`) |
| `NTP_SERVERS` | No | Comma-separated NTP servers (default: `pool.ntp.org`) |
| `PROXY_HOST` | No | Proxy host for Cisco cloud access — leave empty to disable |

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

A custom config file can be passed as an argument:

```bash
IMAGE_FILE=/path/to/image.tar bash deploy.sh my-site.conf
```

---

## What deploy.sh does

| Step | Action |
|---|---|
| 0 | Delete existing instance and all `{VM_HOSTNAME}-disk-*` volumes |
| 1 | Extract tar, find all `.qcow`/`.qcow2` disk files sorted numerically |
| 2–4 | Upload disks to Glance as `{IMAGE_NAME}-1` … `-8` — skipped if already active with matching size |
| 5 | Read virtual sizes from Glance to correctly size Cinder volumes |
| 6 | Create security group and rules (skipped if already exists) |
| 7 | Create Cinder volumes from images, wait until all are available |
| 8 | Generate cloud-init user data (hostname, DNS, NTP, admin password, proxy) |
| 9 | Boot instance with all 8 volumes attached as SCSI disks |
| 10 | Assign floating IP (if `FLOATING_IP_POOL` is set) |

Glance images are **preserved between runs** — only the instance and volumes are cleaned up in Step 0, so re-deploying does not re-upload 28 GB of disk images.

---

## Accessing the Appliance

The URL and credentials are printed on completion:

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
| 80 | Inbound | HTTP redirect to HTTPS |
| 22 | Inbound | SSH management |
| 443 | Outbound | Cisco cloud connectivity (licensing, updates) |

---

## Cleanup

Re-running `deploy.sh` automatically cleans up the previous deployment. To remove everything manually:

```bash
openstack server delete intersight-appliance --wait
openstack volume list -f value -c ID -c Name | awk '/intersight-appliance-disk-/{print $1}' | xargs openstack volume delete

# To also remove Glance images:
for i in $(seq 1 8); do openstack image delete "intersight-appliance-${i}"; done
```

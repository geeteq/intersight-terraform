# intersight-terraform

Terraform configuration to provision a RHEL9 jumpbox VM on OpenStack with cloud-init.

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.3
- OpenStack application credential in `clouds.yaml`
- RHEL9 image available in your OpenStack cluster

---

## Authentication

Authentication is handled via `clouds.yaml`. Place it at `~/.config/openstack/clouds.yaml` or set the path with `OS_CLIENT_CONFIG_FILE`.

**Application credential (recommended):**
```yaml
clouds:
  openstack:
    auth:
      auth_url: https://your-cluster:13000/v3
      application_credential_id: "<id>"
      application_credential_secret: "<secret>"
    auth_type: v3applicationcredential
    interface: public
    identity_api_version: 3
```

See [TROUBLESHOOT.md](../jumpbox-provision/TROUBLESHOOT.md) for auth issues.

---

## Usage

### 1. Copy and fill in variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values — at minimum set `network_name` and `ssh_public_key`.

### 2. Initialise Terraform

```bash
terraform init
```

### 3. Plan

```bash
terraform plan
```

### 4. Apply

```bash
terraform apply
```

### 5. Connect

The SSH command is printed in the outputs:

```
Outputs:

instance_id  = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
instance_ip  = "10.0.0.10"
floating_ip  = "203.0.113.10"
ssh_command  = "ssh baremetal@203.0.113.10"
```

### 6. Destroy

```bash
terraform destroy
```

---

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `cloud_name` | Cloud name in clouds.yaml | `openstack` |
| `vm_name` | VM name | `jumpbox` |
| `image_name` | RHEL9 image name in OpenStack | `rhel9` |
| `flavor_name` | Flavor name | `m1.medium` |
| `network_name` | Network to attach the VM to | required |
| `security_groups` | Security groups | `["default"]` |
| `availability_zone` | Availability zone | `nova` |
| `floating_ip_pool` | External network for floating IP | `""` (skip) |
| `baremetal_user` | User created via cloud-init | `baremetal` |
| `ssh_public_key` | SSH public key for baremetal user | required |
| `packages` | Packages installed via cloud-init | `["mtr"]` |

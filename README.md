# Ansible K3s HA cluster

This project deploys a six-node K3s cluster:

- **3 K3s server nodes** running the Kubernetes control plane and embedded etcd.
- **3 K3s agent nodes** dedicated to application workloads.
- Server changes are applied one node at a time to preserve etcd quorum.
- Kubernetes Secrets are encrypted at rest.
- Embedded-etcd snapshots are compressed every 12 hours and 14 snapshots are retained.
- Server and agent joins use separate credentials.

The server count may be increased later, but embedded-etcd clusters should retain an odd number of server nodes.

## Repository layout

```text
ansible-k3s-ha/
├── ansible.cfg
├── inventories/production/
│   ├── hosts.yml
│   └── group_vars/
├── playbooks/
│   ├── site.yml
│   ├── validate.yml
│   └── reset.yml
├── roles/
│   ├── preflight/
│   ├── prerequisites/
│   ├── k3s_node/
│   └── cluster_validate/
└── artifacts/                 # generated kubeconfig and node report
```

## Assumptions

The three server nodes are combined control-plane and embedded-etcd nodes, not etcd-only nodes. Hosts must use unique hostnames, run a systemd-based Debian/Ubuntu or Red Hat-family distribution, have Python available for Ansible, and permit passwordless sudo or another configured Ansible become method.

Use SSD-backed storage for the server nodes. A practical small-cluster baseline is 2 vCPU and 4 GB RAM per server; size workers for their workloads.

## Required network access

Permit these flows inside the cluster network:

| Protocol/port | Source | Destination | Purpose |
|---|---|---|---|
| TCP 6443 | all nodes and administrators | all servers or the fixed endpoint | K3s supervisor and Kubernetes API |
| TCP 2379-2380 | servers | servers | embedded-etcd peer/client traffic |
| UDP 8472 | all nodes | all nodes | Flannel VXLAN |
| TCP 10250 | all nodes | all nodes | kubelet metrics and management |

Do not expose UDP 8472 to the public internet. If a host firewall remains enabled, also permit traffic for the configured pod and service CIDRs according to the K3s firewall guidance. This project does not modify host or cloud firewalls. Each node also needs outbound HTTPS access to retrieve the pinned installer and K3s release, directly or through proxy values in `k3s_download_environment` and `k3s_install_environment`.

## 1. Install the controller dependencies

Use Python 3.12 or newer on the Ansible controller.

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
```

Only `ansible-core` is required for deployment; the other packages provide linting.

## 2. Edit the inventory

Replace the addresses and SSH user in `inventories/production/hosts.yml`. With host-key checking enabled, connect to each node once or add its key to `known_hosts` before deployment.

The `k3s_bootstrap` group must contain exactly one node. The remaining servers belong in `k3s_server_joiners`; workers belong in `k3s_agents`.

## 3. Configure the API/registration endpoint

By default, nodes join through the bootstrap server address. That is sufficient to create the cluster, and K3s agents establish connections to the server pool after registration, but the exported kubeconfig will still depend on that first address.

For a fully highly available endpoint, provision a TCP load balancer, DNS name, or virtual IP in front of all three server nodes and set:

```yaml
k3s_fixed_registration_address: "k3s-api.example.internal"
```

The address is automatically added to the Kubernetes API certificate SANs. A load balancer should forward TCP 6443 to all three servers and only send traffic to healthy backends.

## 4. Create persistent join credentials

The recommended method is Ansible Vault:

```bash
cp inventories/production/group_vars/all/vault.yml.example \
  inventories/production/group_vars/all/vault.yml

# Replace both placeholder values; generate each with:
openssl rand -hex 32

ansible-vault encrypt inventories/production/group_vars/all/vault.yml
```

Then deploy with `--ask-vault-pass`, a vault password file, or your existing vault identity configuration.

Environment variables are also supported:

```bash
export K3S_SERVER_TOKEN="$(openssl rand -hex 32)"
export K3S_AGENT_TOKEN="$(openssl rand -hex 32)"
```

Store those values securely and reuse them on later runs. The server token is required when restoring an embedded-etcd snapshot.

## 5. Deploy

```bash
make deploy ARGS=--ask-vault-pass
```

Equivalent command:

```bash
ansible-playbook \
  -i inventories/production/hosts.yml \
  playbooks/site.yml \
  --ask-vault-pass
```

The playbook performs these phases:

1. Validates topology, release settings, and credentials.
2. Prepares all hosts, disables swap, loads kernel modules, and applies networking sysctls.
3. Initializes the first server with `cluster-init`.
4. Joins the other two servers serially to embedded etcd.
5. Joins the three workers serially.
6. Waits for all nodes to become Ready, verifies the etcd and worker counts, and exports local artifacts.

Generated files:

```text
artifacts/kubeconfig
artifacts/nodes.txt
```

Use the cluster:

```bash
export KUBECONFIG="$PWD/artifacts/kubeconfig"
kubectl get nodes -o wide
```

## Validation and repeat runs

Run validation without reinstalling:

```bash
make validate
```

The deployment is idempotent. Re-running `site.yml` applies configuration changes and only restarts a node when its K3s configuration, binary version, or service installation changes.

## Rolling upgrades

Change `k3s_version` in `inventories/production/group_vars/all/main.yml`, then run the deployment again. The bootstrap server and joining servers are processed one at a time, preserving quorum; workers are also processed serially.

Review K3s and Kubernetes release notes before crossing minor versions, and test application compatibility first.

## Adding nodes

Add another worker under `k3s_agents` and rerun the deployment.

To add server capacity, add nodes under `k3s_server_joiners` while keeping the total number of servers odd. For example, move from three directly to five servers rather than four.

Custom node labels and taints in the K3s config are registration-time settings. Changing them in this repository does not retroactively alter an already registered node; use `kubectl label` or `kubectl taint`, or remove and rejoin the node. The standard worker role label is deliberately applied after join through the Kubernetes API because nodes may not self-assign reserved role labels.

## Snapshots and disaster recovery

K3s creates scheduled embedded-etcd snapshots locally on every server. Local copies protect against some logical failures, but they do not protect against loss of the server or site. Replicate snapshots to protected off-node storage or add K3s S3 snapshot settings through `k3s_server_extra_config` and vaulted credentials. On Ubuntu releases older than 24.04, the preparation role disables enabled `nm-cloud-setup` units and reboots before K3s installation. Set `k3s_force_disable_nm_cloud_setup: true` to apply that handling on another image.

Never rotate or replace `k3s_server_token` merely by editing the inventory. Use the supported K3s token rotation workflow and update the vault only after the cluster token has been rotated successfully.

## Destructive reset

The reset playbook runs the K3s-provided uninstall scripts and deletes all cluster state:

```bash
make reset
```

The explicit `k3s_reset_confirmation=destroy` guard is included in the Make target. Snapshot and export anything needed before running it.

## Important variables

| Variable | Default | Purpose |
|---|---|---|
| `k3s_version` | `v1.37.0+k3s1` | Pinned K3s release |
| `k3s_fixed_registration_address` | empty | VIP, DNS name, or L4 load-balancer address |
| `k3s_tls_sans` | `[]` | Additional API certificate SANs |
| `k3s_flannel_backend` | `vxlan` | Cluster network backend |
| `k3s_disable_components` | `[]` | Optional packaged components to disable |
| `k3s_secrets_encryption` | `true` | Encrypt Kubernetes Secrets in the datastore |
| `k3s_etcd_snapshot_retention` | `14` | Local scheduled snapshots retained per server |
| `k3s_download_environment` | `{}` | Proxy environment for Ansible HTTP downloads |
| `k3s_install_environment` | `{}` | Additional environment for the K3s installer |
| `k3s_force_disable_nm_cloud_setup` | `false` | Force legacy `nm-cloud-setup` handling |
| `k3s_server_extra_config` | `{}` | Additional server `config.yaml` keys |
| `k3s_agent_extra_config` | `{}` | Additional agent `config.yaml` keys |

This repository intentionally leaves the external load balancer/VIP, DNS, firewall policy, off-node snapshot storage, and application storage classes to the surrounding infrastructure.

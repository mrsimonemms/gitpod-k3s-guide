# Running Gitpod in [k3s](https://k3s.io)

> Archived: please see [Gitpod Self-Hosted](https://github.com/mrsimonemms/gitpod-self-hosted) instead

Before starting the installation process, you need:

- Target building resources.
  - Ubuntu 20.04/22.04 machine(s) with SSH credentials.
    - At least one, but also the script can also work for multiple nodes. The hostname of each node can be called `node0`, `node1`, etc.
    - All nodes have ports 22 (SSH), 80 (HTTP), 443 (HTTPS) and 6443 (Kubernetes) exposed. All nodes are better to be in the same vlan so they can communicate with each other.
    - Each node needs to have least 4 cores, 16GB RAM and 100GB storage.
  - A domain and some wildcard subdomains managed by Cloudflare (free), GCP, or Route53 [see price](https://aws.amazon.com/route53/pricing/). Please see the "DNS and TLS configured" section in the [Gitpod docs](https://www.gitpod.io/docs/configure/self-hosted/latest/installing-gitpod) for more information. These DNS services will have and manage free Let's Encrypt certificates for you. If you choose not to use these commercial DNS services, you will need to use self-signed certificates and manage them manually.
- A `.env` file or environment variables with basic details about the environment.
  - We provide an example of such file [here](.env.example)
- Building environment. You can either:
  - Build on a local Linux machine - needs to install kubectl, Helm, K3sup. You may need to clean your `${HOME}/.kube` directory if there was a previous `gitpod-k3s` entry.
  - Use [Docker](https://docs.docker.com/engine/install) installed on your machine and Docker file is at .gitpod/gitpod.Dockerfile.
  - Even better, use a [Gitpod workspace](https://gitpod.io/#https://github.com/MrSimonEmms/gitpod-k3s-guide)😀.

<details>
<summary>Example VM on GCP</summary>

Create GCP VM with Ubuntu 20.04 with 4 cores, 16GB of RAM, and 100GB of storage:

```bash
gcloud compute instances create gitpod-x509 \
  --image=ubuntu-2004-focal-v20220712 \
  --image-project=ubuntu-os-cloud \
  --machine-type=n2-standard-4 \
  --boot-disk-size=100GB \
  --tags k3s
# Created [https://www.googleapis.com/compute/v1/projects/adrien-self-hosted-testing-5k4/zones/us-west1-c/instances/gitpod-k3s].
# NAME         ZONE        MACHINE_TYPE   PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP     STATUS
# gitpod-k3s  us-west1-c  n2-standard-4               10.138.0.6   169.254.87.220  RUNNING
```

A firewall rule must be added to allow the current system to connect to the Kubernetes API. As we
don't want to expose the Kubernetes API to the entire Internet this firewall rule allows the current
host to connect to the k3s VM.

**Note**: If you're using a remote workspace (such as Gitpod) you'll need to include the public IP
address the Gitpod instance as well as the public IP address of your local machine as the source ranges
of this firewall rule.

```bash
gcloud compute firewall-rules create k3s \
  --source-ranges="$(curl -s ifconfig.me)/32" \
  --allow=tcp:6443,tcp:443,tcp:80 \
  --target-tags=k3s
```

```shell
gcloud compute config-ssh
# You should now be able to use ssh/scp with your instances.
# For example, try running:
#
# ssh gitpod-k3s.us-west1-c.adrien-self-hosted-testing-5k4
```

</details>

## DNS and TLS

There are a number of options you may use for your DNS and TLS certificates:

- [Cloudflare](https://cloudflare.com) - certificate verified via LetsEncrypt
- A self-signed certificate - you will need to install your CA certificate (full instructions in KOTS dashboard)
- None - you can do this manually

This has been tested on bare-metal Ubuntu and [Multipass](https://multipass.run). Multi-node clusters
are supported - it is assumed that all nodes are configured identically.

**To start the installation, execute:**

```shell
./setup.sh install
```

This process takes about 5 minutes. This will configure your k3s instance so it can accept a Gitpod installation.

As k3s tends to use the internal IP address, you will need to manually configure A records for:

- `$DOMAIN`
- `*.$DOMAIN`
- `*.ws.$DOMAIN`

Upon completion, it will print the config for the resources created and instructions on what to do next.

### Monitoring

You can optionally install a [monitoring application](https://github.com/MrSimonEmms/gitpod-monitoring) to
provide observatibility for you cluster.

### Troubleshooting

- Pods running out of resources

  This is a single-instance cluster. You will need to either add additional nodes or use a machine with greater resources.
  The seggested size is 4vCPUs and RAM in excess of 16GB. Disk size should also break a minimum of 100GB.

- Some pods never start (`Init` state)

  ```shell
  kubectl get pods -l component=proxy
  NAME                     READY   STATUS    RESTARTS   AGE
  proxy-5998488f4c-t8vkh   0/1     Init 0/1  0          5m
  ```

  The most likely reason is that the [DNS01 challenge](https://cert-manager.io/docs/configuration/acme/dns01/) has yet to resolve. If using `MANAGED_DNS_PROVIDER`, you will need to update your DNS records to the IP of your machine.

  Once the DNS record has been updated, you will need to delete all Cert Manager pods to retrigger the certificate request

  ```shell
  kubectl delete pods -n cert-manager --all
  ```

  After a few minutes, you should see the `https-certificate` become ready.

  ```shell
  kubectl get certificate
  NAME                        READY   SECRET                      AGE
  https-certificates          True    https-certificates          5m
  ```

## Removing a node

Remove a node from the cluster by running:

```shell
./setup.sh delete-node <node name>
```

### Warnings

- If run on a control-plane node, this may have severe negative consequences for your cluster's long-term health.
- This will only remove the node from the cluster. It does not uninstall k3s from the machine or delete the VM.

## Destroy the resources

Remove k3s from your machine by running:

```shell
./setup.sh uninstall
```

If you created any cloud resources you can delete them with the following:

- GCP
  <details>
  <summary>GCP resource cleanup</summary>

  ```shell
  gcloud compute firewall-rules delete k3s --quiet
  gcloud compute instances delete gitpod-k3s --quiet
  ```

  </details>

## Retrieving credentials

Sometimes, you just want to get the credentials

```shell
./setup.sh credentials
```

## Contributing

Contributions are always welcome. Please raise an issue first before raising a pull request.

Commit messages must adhere to the [Conventional Commit format](https://www.conventionalcommits.org/en/v1.0.0/).

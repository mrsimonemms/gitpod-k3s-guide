# Running Gitpod in [k3s](https://k3s.io)

Before starting the installation process, you need:

- An Ubuntu 20.04 machine with SSH credentials
  - This must have ports 22 (SSH), 80 (HTTP), 443 (HTTPS) and 6443 (Kubernetes) exposed
- A `.env` file with basic details about the environment.
  - We provide an example of such file [here](.env.example)
- [Docker](https://docs.docker.com/engine/install) installed on your machine, or better, a [Gitpod workspace](https://github.com/MrSimonEmms/gitpod-k3s-guide) :)

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


# Running Gitpod in [k3s](https://k3s.io)

Before starting the installation process, you need:

- An Ubuntu 20.04 machine with SSH credentials
  - This must have ports 22 (SSH), 80 (HTTP), 443 (HTTPS) and 6443 (Kubernetes) exposed
- A `.env` file with basic details about the environment.
  - We provide an example of such file [here](.env.example)
- [Docker](https://docs.docker.com/engine/install) installed on your machine, or better, a [Gitpod workspace](https://github.com/MrSimonEmms/gitpod-k3s-guide) :)

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

# k8s-pi

Documents the build out and configuration of my home kubernetes lab using Raspberry Pi 4's and k3s.

# Hardware and Things

These are specific to my setup, so adjust accordingly!

### Network:

* Ubiquiti Unifi Security Gateway/Router
* Ubiquiti Unifi 24-port PoE switch

### Raspberry Pi

* 4x Raspberry Pi 4b with 8 GB RAM
* One is dedicated for the control plane and the rest are for nodes.
* Obviously, this is not configure for HA :)

### Misc:

* 4-node rack: https://www.amazon.com/dp/B096MKY263
* I also use the Raspberry Pi PoE+ Hat (https://www.raspberrypi.org/products/poe-plus-hat/) to provide power and data to each node from my switch. You must have a PoE capable switch with enough available power!

> :information_source: Under normal/idle load, the power draw for each node is ~5W: ![image](https://user-images.githubusercontent.com/426666/134377917-7ff08ebe-8a09-49d4-afe4-0cf0c8bc274d.png)


### Notes

* Each node has been assigned a static IP on a separate VLAN from my main network: 10.0.2.{10,11,12,13}
* Internal domain has been assigned for VLAN (shantylab.local)
* Each node has been given a specific hostname: k8s-node{1,2,3,4}.shantylab.local
* Each node has been provisioned using Ubuntu 21.04

# Prerequisites

You must have a machine on the network that can SSH into the Raspberry Pi machines and that machine needs the following:

* ansible: https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html
* k3sup: https://github.com/alexellis/k3sup
* kubectl: https://kubernetes.io/docs/tasks/tools/
* helm: https://helm.sh/
* helm diff plugin: https://github.com/databus23/helm-diff
* helmsman: https://github.com/Praqma/helmsman

### Provision Raspberry Pi machines with Ubuntu

* Power off the machines
* Label the machines however you would like (I used a label maker)
* Remove the SD cards and remember which is for which node
* Using the Raspberry Pi Imager (https://www.raspberrypi.org/software/), install Ubuntu 21.04 Server on to the SD cards for each of your nodes
* Before unmounting the SD card, modify the `user-data` file in the root of your SD card to automate the configuration of a few things at boot (user, authorized keys, hostname, etc)
* Unmount the SD card
* Insert the SD cards into the appropriate node
* Power up the nodes
* Confirm you can SSH to each of the nodes using the user and SSH key you configured with cloud-init

### Cloud Init Example

Below is close to what I used on each of my nodes. For more information on how to use cloud-init and cloud-config files, see: https://cloudinit.readthedocs.io/en/latest/topics/format.html#cloud-config-data

```
#cloud-config

ssh_pwauth: false

groups:
  - ubuntu: [root, sys]

users:
  - default
  - name: abe
    gecos: abe
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    ssh_import_id: None
    lock_passwd: true
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-rsa YOUR PUBLIC KEY GOES HERE

# Set the hostname of the node. This will need to be
# done for each node's cloud-init
hostname: k8s-node1
```

# Getting Started

At this point, you should have all of your Raspberry Pi nodes provisioned with Ubuntu, they should have had a baseline configuration with cloud-init, and you should be able SSH to each of them. The next steps will be to start the install and configuration of your k8s cluster.

### Setup ansible

I use ansible for one-off commands that need to run across all (or a subset) of my nodes. For that, I installed ansible and set up my hosts file in `/etc/ansible/hosts`. Take a look at my [ansible hosts file](ansible/hosts)

Test it out:

```
$ ansible k8s -m shell -a 'whoami'
k8s-node4.shantylab.local | CHANGED | rc=0 >>
abe
k8s-node2.shantylab.local | CHANGED | rc=0 >>
abe
k8s-node1.shantylab.local | CHANGED | rc=0 >>
abe
k8s-node3.shantylab.local | CHANGED | rc=0 >>
abe
```

### Install k3s

> :warning: This is not meant to be a k3s cluster in HA mode. For more information on how to do this, please see their docs: https://rancher.com/docs/k3s/latest/en/installation/ha-embedded/

I used `k3sup` to do all the heavy lifting for me. Pay special attention to the arguments provided to the command and adjust as necessary. Also, note that I have intentionally disabled both the `servicelb` and `traefik` services that `k3sup` wants to install by default. I will install and configure such things later to have more control over DNS and ingress.

##### Start with the control plane

```
k3sup install --k3s-channel latest --host k8s-node1.shantylab.local --user abe --ssh-key ~/.ssh/id_rsa_k8s --k3s-extra-args '--disable servicelb --disable traefik --flannel-backend host-gw'
```

This will dump a `kubeconfig` file that can be used with `kubectl`. I don't manage any other clusters, so I moved this file to my home directory to be used by default. If you already have a kube config file, you should only copy in the bits necessary and not accidentally overwrite your file.

```
mv kubeconfig ~/.kube/config
```

Test it out:

```
$ kubectl get nodes
NAME        STATUS   ROLES                  AGE     VERSION
k8s-node1   Ready    control-plane,master   7d12h   v1.21.4+k3s1
```

##### Install worker nodes

```
k3sup join --server-host k8s-node1.shantylab.local --server-user abe --k3s-channel latest --user abe --ssh-key ~/.ssh/id_rsa_k8s --host k8s-node2.shantylab.local

k3sup join --server-host k8s-node1.shantylab.local --server-user abe --k3s-channel latest --user abe --ssh-key ~/.ssh/id_rsa_k8s --host k8s-node3.shantylab.local

k3sup join --server-host k8s-node1.shantylab.local --server-user abe --k3s-channel latest --user abe --ssh-key ~/.ssh/id_rsa_k8s --host k8s-node4.shantylab.local
```

And test it out:

```
$ kubectl get nodes
NAME        STATUS   ROLES                  AGE     VERSION
k8s-node1   Ready    control-plane,master   7d12h   v1.21.4+k3s1
k8s-node3   Ready    <none>                 7d12h   v1.21.4+k3s1
k8s-node2   Ready    <none>                 7d12h   v1.21.4+k3s1
k8s-node4   Ready    <none>                 7d12h   v1.21.4+k3s1
```

```
kubectl get all -n kube-system
```

You should have the core services installed into the cluster (coredns, metrics, local path provisioning, etc). We'll install some more things next.

### Install additional services

For this step, we'll use `helmsman` to automate the install of additional services. Take a look at the [core helmsan config file](helmsman-core.yaml) for more info. I'll give a brief explanation of what I chose to install and why below.

##### Core Services

* [Traefik](https://traefik.io/): Reverse proxy and ingress controller that I use (with MetalLB) to provide external access to other services
* [MetalLB](https://metallb.universe.tf/): Bare metal load balancer that can assign real IP addresses in my home network to k8s services of type `LoadBalancer`.
* [Postgres](https://www.postgresql.org/): We need a database for PowerDNS
* [PowerDNS](https://www.powerdns.com/auth.html): Provides an API-driven DNS server that works with `external-dns` to resolve services and ingress internally in my cluster to my external network.
* [external-dns](https://github.com/kubernetes-sigs/external-dns): Watches for changes to internal services and ingress and informs `PowerDNS` of those changes, causing any external DNS resolution on the appropriate domain to be forwarded to `PowerDNS`. For example, I may want to install ArgoCD in the cluster and make it available on my network as `argocd.k8s.shantylab.local`. If the service or ingress changes, `external-dns` will make the necessary API call to `PowerDNS` to keep DNS working like it should.

To make this as simple as possible to install, I use `helmsman` to manage a set of helm charts for the above services.

To install all the things:

```
helmsman -f helmsman-core.yaml --apply
```

I highly recommend looking at `helmsman --help` and the [helmsman documentation](https://github.com/Praqma/helmsman/blob/master/docs/how_to/README.md) for what all is possible here.

Each helm chart managed by `helmsman` uses a corresponding values file for configuration. I've made choices that work for me in my home lab and network, but you should take a look at them and update as necessary. Some important things to point out:

* I use hardcoded IP addresses for some services so they don't change. `MetalLB` allows for this as long as there's no collision with an existing Service's `loadBalancerIP`.
* My lab's internal domain is `shantylab.local` and I've configured my network to do DNS forwarding for all `k8s.shantylab.local` to my exposed `PowerDNS` service at a hardcoded IP. I've configured my exposed services to be in these domains.
* I configured `MetalLB` to issue IP addresses in a specific range on my VLAN. You must change this depending on your personal network settings. I highly recommend allowing `MetalLB` to issue a specific range of IP addresses on a network and disable your DHCP server from also issuing addresses in that range.

# Useful URLs

* [Traefik Dashboard](http://traefik.k8s.shantylab.local:9000/dashboard/#/)

# FAQ

### How do I expose a service/ingress and get a DNS entry for it?

Easy...sort of! It depends on what you're exposing.

> :information_source: This also requires that `PowerDNS` be configured for the domain/zone (e.g, `k8s.shantylab.local`) and `external-dns` configured correctly to interact with `PowerDNS`

**For IngressRoute/Ingress resources**, it's kind of weird and I would love to figure out how to make it unweird. Basically, we're using Traefik 2.x to manage a single ingress controller and corresponding routing via its reverse proxy. To do this, we need to create a Traefik provided CRD resource called `IngressRoute` which is not the same as the Kubernetes `Ingress` resource. Unfortunately, Traefik doesn't appear to support `Ingress` and external-dns doesn't appear to support `IngressRoute`. So the silly workaround is to use `IngressRoute` like normal, specify the host, paths, endpoints, headers, middleware, etc, but also provide a "dummy" `Ingress` resource that external-dns can watch and update DNS for. See the [nginx example](nginx/nginx.yaml) for how I've done this.

**For Service resources**, only those of `type=LoadBalancer` will be considered. Beyond that, you have a couple options for deciding the actual FQDN for the DNS record.

1. If you would like your DNS record to be named according to the name of your Service (e.g, `<service name>.k8s.shantylab.local`, then you don't have to do anything because `external-dns` has been configured by default to automatically build the FQDN using its `--fqdn-template` setting.
2. If you want to override the FQDN, then provide the `external-dns.alpha.kubernetes.io/hostname` annotation to your Service and specify the FQDN as the value.

Here's a service that will end up with `nginx.k8s.shantylab.local` as an A record in DNS simply because it exists and is of type `LoadBalancer`. The `k8s.shantylab.local` will automatically be applied by `external-dns` due to the `--fqdn-template` setting being used.

```
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  type: LoadBalancer
```

And here's the same Service, but it overrides the FQDN using the appropriate annotation:

```
apiVersion: v1
kind: Service
metadata:
  name: nginx
  annotations:
    external-dns.alpha.kubernetes.io/hostname: foobar.k8s.shantylab.local
spec:
  type: LoadBalancer
```

### How can I disable a Service from being exposed?

You have a couple of options depending on what you're trying to do.

1. If you just don't want the Service exposed externally AT ALL, then drop the `type=LoadBalancer` and that should do the trick.
2. If you want it exposed, but no DNS entry for it, then you can use the `external-dns.alpha.kubernetes.io/hostname` annotation on the Service and set its value to an empty string.

The following example will expose the Service on some IP address provided by `MetalLB`, but no DNS record will be generated in `PowerDNS`:

```
apiVersion: v1
kind: Service
metadata:
  name: nginx
  annotations:
    external-dns.alpha.kubernetes.io/hostname: ""
spec:
  type: LoadBalancer
```

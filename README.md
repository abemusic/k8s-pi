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

NOTE: This is not meant to be a k3s cluster in HA mode. For more information on how to do this, please see their docs: https://rancher.com/docs/k3s/latest/en/installation/ha-embedded/

I used `k3sup` to do all the heavy lifting for me. Pay special attention to the arguments provided to the command and adjust as necessary. Also, note that I have intentionally disabled both the `servicelb` and `traefik` services that `k3sup` wants to install by default. I will install and configure such things later to have more control over DNS and ingress.

##### Start with the control plan

```
k3sup install --k3s-channel latest --host k8s-node1.shantylab.local --user abe --ssh-key ~/.ssh/id_rsa_k8s --k3s-extra-args '--disable servicelb --disable traefik --flannel-backend host-gw'
```

This will dump a `kubeconfig` file that can be used with `kubectl`. I don't manage any other clusters, so I moved this file to my home directory to be used by default. If you already have a kubee config file, you should only copy in the bits necessary and not accidentally overwrite your file.

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

For this step, we'll use `helmsman` to automate the install of additional services. Take a look at the [coree helmsan config file](helmsman-core.yaml) for more info. I'll give a brief explanation of what I chose to install and why below.

##### Core Services

* [Traefik](https://traefik.io/): Reverse proxy and ingress controller that I use (with MetalLB) to provide external access to other services
* [MetalLB](https://metallb.universe.tf/): Bare metal load balancer that can assign real IP addresses in my home network to k8s services of type `LoadBalancer`.
* [Postgres](): We need a database for PowerDNS
* [PowerDNS](https://www.powerdns.com/auth.html): Provides an API-driven DNS server that works with `external-dns` to resolve services and ingress internally in my cluster to my external network.
* [external-dns](https://github.com/kubernetes-sigs/external-dns): Watches for internal services and ingress and informs `PowerDNS` of any changes that I would like to be made available externally to the cluster. For example, I may want to install ArgoCD in the cluster and make it available on my network as `argocd.k8s.shantylab.local`. If the service or ingress changes, external-dns will make the necessary change to my DNS server for proper resolution.

To make this as simple as possible to install, I use `helmsman` to manage a set of helm charts for the above services.

To install all the things:

```
helmsman -f helmsman-core.yaml --apply
```

I highly recommend looking at `helmsman --help` and the [helmsman documentation](https://github.com/Praqma/helmsman/blob/master/docs/how_to/README.md) for what all is possible here.

Each helm chart managed by `helmsman` uses a corresponding values file for configuration. I've made choices that work for me in my home lab and network, but you should take a look at them and update as necessary. Some important things to point out:

* I use hardcoded IP addresses for some services so they don't change. `MetalLB` allows for this as long as there's no collision with an existing Service's `loadBalancerIP`.
* My lab's internal domain is `shantylab.local` and I've configured my network to do DNS forwarding for all `k8s.shantylab.local` to my exposed `PowerDNS` service at a hardcoded IP. I've configured my exposed services to be in these domains.
* I configured `MetalLB` to issue IP addresses in a specific range on my VLAN. You must change this depending on your personal network settings. I highly recommend allowing `MetalLB` to issue a specific range IP addresses on a network that are not being managed by a DHCP server in your network.

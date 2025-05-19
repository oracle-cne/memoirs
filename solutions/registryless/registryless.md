# Deploying in Environments with no Container Image Registry

Running a container image registry is a significant complication in many
Kubernetes environments.  It is an extra component that needs to be administered
and maintained.  Registries require compute and storage resources that may
be scarce.  In these environments, it may be useful to deploy cluster with
all the necessary container images pre-loaded onto the system.

Preloading container images has its own set of problems.  The first is actually
getting the images onto the nodes.  The second is to work around one of the
less commonly understood behaviors of Cri-O.  In order to prevent corruption of
the container image store, Cri-O will delete the entire store if it detects
that a system has been reset without a clean shutdown.  In the case of clusters
with pre-loaded images, that means that events like a power failure or a kernel
panic break the deployment by deleting all the container images.  If no registry
is available, it is not possible to recover without manual intervention.

The Open Container Initiative ecosystem has ways to account for this behavior.
One of the configuration options available for container runtimes is the ability
to set a collection of read-only image stores that sit alongside the default.
By pre-loading images into an alternate store and configuring the container
runtime to leverage that store, the problems enumerated above can be mitigated.

# Reproducing the Issue.

Reproducing the problem is easy.  Create a cluster with the `libvirt` provider,
then pull and image, and hard reset the VM.

First start a vanilla cluster.
```
$ ocne cluster start -C registrydemo
INFO[2025-05-19T17:48:18Z] Creating new Kubernetes cluster with version 1.31 named registrydemo 
INFO[2025-05-19T17:49:09Z] Waiting for the Kubernetes cluster to be ready: ok 
INFO[2025-05-19T17:49:10Z] Installing core-dns into kube-system: ok 
...
```

Pull an image.

```
$ export KUBECONFIG=$(ocne cluster show -C registrydemo)
$ ocne cluster console --direct --node registrydemo-control-plane-1 -- crictl pull container-registry.oracle.com/os/oraclelinux:8-slim
Image is up to date for container-registry.oracle.com/os/oraclelinux@sha256:07167d52410a9a2c69b26b33f9a12eb89e520b632c606d2e26545834e52f62af

$ ocne cluster console --direct --node registrydemo-control-plane-1 -- crictl images
$ ocne cluster console --direct --node registrydemo-control-plane-1 -- crictl images | grep 8-slim
container-registry.oracle.com/os/oraclelinux                  8-slim              86d8648645740       118MB
```

Now do a hard reset on the node by destroying the domain and starting it.

``
$ sudo virsh destroy registrydemo-control-plane-1
Domain 'registrydemo-control-plane-1' destroyed

$ sudo virsh start registrydemo-control-plane-1
Domain 'registrydemo-control-plane-1' started
```

Wait a bit for the node to come back up and then list the images.  Notice that
the image that was pulled is now missing.
```
$ ocne cluster console --direct --node registrydemo-control-plane-1 -- crictl images | grep 8-slim
```

Destroy the cluster so there is a fresh start for the next step.

```
$ ocne cluster delete -C registrydemo
```

# Mitigating the issue.

To mitigate the issue, re-create the custer with a configuration that lets
Cri-O look for images in an alternate location.  Pulling a container image to
that location will prevent Cri-O from deleting it.  Note that in
`/etc/containers/storage.conf` there are two entries for `additionalimagestores`.
One of those, `/usr/ock/containers` is required for OCK to find the Kubneretes
container images.  The other is the alternate store.

```
$ ocne cluster start -C registrydemo -c <(cat << 'EOF'
extraIgnitionInline: |
  variant: fcos
  version: 1.5.0
  storage:
    directories:
    - path: /var/images
    files:
    - path: /etc/containers/storage.conf
      overwrite: true
      contents:
        inline: |
          [storage]
          driver = "overlay"
          runroot = "/run/containers/storage"
          graphroot = "/var/lib/containers/storage"
          
          [storage.options]
          additionalimagestores = [
            "/var/images",
            "/usr/ock/containers"
          ]
          pull_options = {enable_partial_images = "false", use_hard_links = "false", ostree_repos=""}
          
          [storage.options.overlay]
          mountopt = "nodev,metacopy=on"
EOF
)
...
```

Now pull some images.  One goes to the typical store, while the other goes to
the alternate store.

``
$ export KUBECONFIG=$(ocne cluster show -C registrydemo)
$ ocne cluster console --direct --node registrydemo-control-plane-1 -- crictl pull container-registry.oracle.com/os/oraclelinux:9-slim

$ ocne cluster console --direct --node registrydemo-control-plane-1 -- podman pull container-registry.oracle.com/os/oraclelinux:8-slim
Trying to pull container-registry.oracle.com/os/oraclelinux:8-slim...
...
Writing manifest to image destination
86d8648645740bbb1fa5b63007f3acba50b536ecf41ef2683e4d281cafbd19ed

$ ocne cluster console --direct --node registrydemo-control-plane-1 -- podman --root=/var/images pull container-registry.oracle.com/os/oraclelinux:9-slim
Trying to pull container-registry.oracle.com/os/oraclelinux:9-slim...
...
Writing manifest to image destination
86d8648645740bbb1fa5b63007f3acba50b536ecf41ef2683e4d281cafbd19e

```

Notice how the image that was pulled to the normal store is read-write while the
one pulled to the alternate store is read-only.

```
$ ocne cluster console --direct --node registrydemo-control-plane-1 -- podman images
REPOSITORY                                                   TAG         IMAGE ID      CREATED       SIZE        R/O
container-registry.oracle.com/os/oraclelinux                 9-slim      d88bc436c213  2 weeks ago   116 MB      true
container-registry.oracle.com/os/oraclelinux                 8-slim      86d864864574  3 weeks ago   118 MB      false
...
```

Now restart the domain

```
$ sudo virsh destroy registrydemo-control-plane-1

$ sudo virsh start registrydemo-control-plane-1
```

Now wait a bit for the node to come back up, then check the images.  Notice that
the image pulled to the default store has been removed but the image pulled to
the alternate store is still available.

```
$ ocne cluster console --direct --node registrydemo-control-plane-1 -- podman images | grep slim
container-registry.oracle.com/os/oraclelinux                 9-slim      d88bc436c213  2 weeks ago   116 MB      true
```

This works because of the way that `additionalimagestores` are handled by
container runtimes.  All additional image stores are set as read-only regardless
of whether or not the actual store is writable.  This prevents Cri-O from
trying to delete those images.  This way, it is possible to load container
images while circumventing Cri-O's image deletion logic.  In doing so, it is
safe to pre-load container images for deployments in evironments where a
container image registry is not available.

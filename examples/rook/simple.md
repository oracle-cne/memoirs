# Rook Cluster on LibVirt Using A Single Disk

For development and testing, it can be useful to create a Ceph cluster using
Rook on a single disk by allocating a partition on an existing disk to store
Ceph data.

# Deploy a Cluster

Ceph wants a lot of disk to function correctly.  Even for testing, it is best
to have more than 200GiB available specifically for Ceph to use when allocating
volume.  Create a cluster with big disks so that it can be given to Ceph.
Configure the cluster nodes to create a big partition after the root partition
for OCK.  With LibVirt, disks are thin provisioned.  It is not necessary to
have the amount of disk space allocated to the nodes actually available on
your system.

```
$ ocne cluster start -C rookdemo -c <(curl https://raw.githubusercontent.com/oracle-cne/memoirs/refs/heads/main/assets/cluster-configs/bigdisk.yaml)
$ export KUBECONFIG=$(ocne cluster show -C rookdemo)
```

# Install Rook

The worker nodes in the cluster will have large partitions at `/dev/sda4`.  This
partition is what Ceph will use for all allocated volumes.

```
$ ocne cluster console --direct --node rookdemo-worker-2 -- lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sda      8:0    0  256G  0 disk 
|-sda1   8:1    0  244M  0 part /boot/efi
|-sda2   8:2    0  488M  0 part /boot
|-sda3   8:3    0 29.3G  0 part /sysroot
`-sda4   8:4    0  226G  0 part 
```

Now install Rook.

```
$ ocne application install --namespace rook-system --name rook --release rook --values https://raw.githubusercontent.com/oracle-cne/memoirs/refs/heads/main/assets/application-configs/rook/simple/values.yaml
```

Now wait for Rook to become available.
```
$ kubectl -n rook-system rollout status deployment rook-ceph-operator -w
$ kubectl -n rook-system get pod -l app=rook-ceph-operator
NAME                                  READY   STATUS    RESTARTS   AGE
rook-ceph-operator-548dd6b98f-2nqfp   1/1     Running   0          3m
```

# Define the Ceph Cluster

Now that Ceph is available, create a Ceph cluster that targets `/dev/sda4`

```
$ kubectl apply -f https://raw.githubusercontent.com/oracle-cne/memoirs/refs/heads/main/assets/application-configs/rook/clusters/sda4.yaml
```

After applying these resources, Rook will begin configuring and creating a
Ceph cluster.  This can take a while to finish.  Many deployments and daemonsets
are installed, and there are some jobs that have non-trivial runtimes.
Eventually, the `rook-system` namespace will look something like this:

```
$ kubectl get pods -n rook-system
NAME                                                         READY   STATUS      RESTARTS   AGE
csi-cephfsplugin-2rqxn                                       2/2     Running     0          3h3m
csi-cephfsplugin-988k8                                       2/2     Running     0          3h3m
csi-cephfsplugin-g69fw                                       2/2     Running     0          3h3m
csi-cephfsplugin-provisioner-7446c8f6d-5v4sr                 5/5     Running     0          3h3m
csi-cephfsplugin-provisioner-7446c8f6d-jsr6n                 5/5     Running     0          3h3m
csi-rbdplugin-8vgbq                                          2/2     Running     0          3h3m
csi-rbdplugin-lg7wb                                          2/2     Running     0          3h3m
csi-rbdplugin-provisioner-c6db4d8f6-fsmcd                    5/5     Running     0          3h3m
csi-rbdplugin-provisioner-c6db4d8f6-wpclv                    5/5     Running     0          3h3m
csi-rbdplugin-snf4x                                          2/2     Running     0          3h3m
rook-ceph-crashcollector-rookdemo-worker-1-9b4658c4d-wq5dx   1/1     Running     0          177m
rook-ceph-crashcollector-rookdemo-worker-2-fd5c79b95-nnlxd   1/1     Running     0          177m
rook-ceph-crashcollector-rookdemo-worker-3-8bcddbd5d-7qlwz   1/1     Running     0          177m
rook-ceph-mgr-a-65d99444fd-k46xf                             2/2     Running     0          178m
rook-ceph-mgr-b-944f5cb64-ph6dt                              2/2     Running     0          178m
rook-ceph-mon-a-757c75dd84-q4qdn                             1/1     Running     0          3h1m
rook-ceph-mon-b-847f5f4777-vx78w                             1/1     Running     0          179m
rook-ceph-mon-c-f7fcbb6f5-bcmbr                              1/1     Running     0          179m
rook-ceph-operator-548dd6b98f-2nqfp                          1/1     Running     0          3h11m
rook-ceph-osd-0-5f4b747865-sg7g4                             1/1     Running     0          177m
rook-ceph-osd-1-54c6bc7c97-f6w9p                             1/1     Running     0          177m
rook-ceph-osd-2-56bbcc975d-vnhsc                             1/1     Running     0          177m
rook-ceph-osd-prepare-rookdemo-worker-1-rfjfl                0/1     Completed   0          177m
rook-ceph-osd-prepare-rookdemo-worker-2-8fb6p                0/1     Completed   0          177m
rook-ceph-osd-prepare-rookdemo-worker-3-98zrb                0/1     Completed   0          177m
```

# Using Storage

At this point, Rook can be used like any other storage provider for Kubernetes.

```
$ kubectl apply -f https://raw.githubusercontent.com/oracle-cne/memoirs/refs/heads/main/assets/kubernetes/simple-pvc-pod.yaml
```

Pod should come right up


```
$ kubectl get pod
NAME     READY   STATUS    RESTARTS   AGE
my-pod   1/1     Running   0          2m44s$
```

The volumes are backed by Ceph

```
$ kubectl get persistentvolumeclaims my-pvc 
NAME     STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS      VOLUMEATTRIBUTESCLASS   AGE
my-pvc   Bound    pvc-a8295ccc-ff25-4466-94d5-8a37ec84f346   5Gi        RWO            rook-ceph-block   <unset>                 3m18s

$ kubectl get persistentvolumes
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM            STORAGECLASS      VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-a8295ccc-ff25-4466-94d5-8a37ec84f346   5Gi        RWO            Delete           Bound    default/my-pvc   rook-ceph-block   <unset>                          3m52s
```

# Cleanup

Delete the cluster.
```
$ ocne cluster delete -C rookdemo
$ unset KUBECONFIG
```
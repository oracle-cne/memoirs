set -x

USER=opc
HOST1=ovs1
HOST2=ovs2
VERSION=1.31
POOL=images
NAME=ovs
BASE_IMAGE=boot-$VERSION.qcow2

deleteResources() {
	NODE_NAME="$1"
	virsh destroy $NODE_NAME
	virsh undefine --nvram $NODE_NAME
	virsh vol-delete --pool $POOL $NODE_NAME.qcow2
	virsh vol-delete --pool $POOL $NODE_NAME.ign
	rm $NODE_NAME.ign
}

deleteCommon() {
	virsh vol-delete --pool $POOL $BASE_IMAGE
	virsh pool-destroy $POOL
	virsh pool-undefine $POOL
	virsh net-destroy ovs
	virsh net-undefine ovs
}

export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST1/system"
deleteResources $NAME-control-plane-1
deleteCommon

export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST2/system"
deleteResources $NAME-worker-1
deleteCommon

ocne cluster delete -C ovs -c clusterConfig.yaml
rm clusterConfig.yaml
rm extraIgnition.yaml

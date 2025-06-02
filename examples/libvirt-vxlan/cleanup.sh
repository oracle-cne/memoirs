set -x

USER=opc
HOST1=ovs1
HOST2=ovs2
VERSION=1.31
POOL=images
NAME=ovs

deleteResources() {
	NODE_NAME="$1"
	virsh destroy $NODE_NAME
	virsh undefine --nvram $NODE_NAME
	virsh vol-delete --pool images $NODE_NAME.qcow2
	virsh vol-delete --pool images $NODE_NAME.ign
}

export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST1/system"
deleteResources $NAME-control-plane-1

export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST2/system"
deleteResources $NAME-worker-1

ocne cluster delete -C ovs -c clusterConfig.yaml

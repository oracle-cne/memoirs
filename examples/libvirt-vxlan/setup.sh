# install stuff
set -x
set -e

SETUP=yes
USER=opc
HOST1=ovs1
HOST2=ovs2
VERSION=1.31
POOL=images
NAME=ovs

BASE_IMAGE=boot-$VERSION.qcow2

if [ -n "$SETUP" ]; then
	# Extract the OCK image to use as the root filesystem for the VMs for
	# the cluster nodes.  This image is uploaded as a LibVirt volume to
	# all the VM hosts.
	podman pull container-registry.oracle.com/olcne/ock:$VERSION
	podman create --name ock$VERSION container-registry.oracle.com/olcne/ock:$VERSION
	podman cp ock$VERSION:/disk/boot.qcow2 $BASE_IMAGE
	podman rm ock$VERSION

	# Do all the host setup
	# - Install LibVirt and OpenVswitch
	# - Configure LibVirt
	# - Configure OpenVswitch
	# - Do all common LibVirt setup
	for host in $HOST1 $HOST2; do
		# If this is an OCI instance, grow the filesystem.
		ssh $USER@$host sudo /usr/libexec/oci-growfs -y || true

		# Install LibVirt and OpenVswitch.  LibVirt is used to create
		# VMs.  OpenVswitch is used to create a VXLAN that the cluster
		# nodes will sit on.  Once installation is complete, both
		# services are started.
		#
		# A OVS bridge is created to host the VXLAN.
		#
		# The SSH user is added to the libvirt and qemu groups so that
		# it can use virsh commands.
		ssh $USER@$host "
			sudo dnf install -y oracle-ovirt-release-el8
			sudo dnf config-manager --enable ol8_kvm_appstream ovirt-4.4 ovirt-4.4-extra
			sudo dnf install -y openvswitch
			sudo dnf module reset -y virt:ol
			sudo dnf module install -y virt:kvm_utils3/common

			# start services
			sudo systemctl enable --now libvirtd.service
			sudo systemctl enable --now openvswitch.service

			# create networks - ovs stuff
			sudo ovs-vsctl add-br ovsbr0
			sudo ip link set ovsbr0 up
			sudo usermod -a -G libvirt,qemu $USER

			# Disable firewall
			sudo systemctl stop firewalld.service
			sudo systemctl disable firewalld.service
		"

		# Create a LibVirt network that is attached to the
		# OpenVswitch bridge.  VMs that are attached to this network
		# can use the VXLAN to communicate with each other.
		export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$host/system"
		virsh net-define <( cat << EOF
<network>
  <name>ovs</name>
  <forward mode='bridge'/>
  <bridge name='ovsbr0'/>
  <virtualport type='openvswitch'/>
</network>
EOF
)

		virsh net-start ovs

		virsh pool-define <(cat << EOF
<pool type='dir'>
  <name>${POOL}</name>
  <capacity unit='bytes'>38069878784</capacity>
  <allocation unit='bytes'>27457032192</allocation>
  <available unit='bytes'>10612846592</available>
  <source>
  </source>
  <target>
    <path>/var/lib/libvirt/images</path>
    <permissions>
      <mode>0711</mode>
      <owner>0</owner>
      <group>0</group>
      <label>system_u:object_r:virt_image_t:s0</label>
    </permissions>
  </target>
</pool>
EOF
)
		virsh pool-start $POOL

		# Upload the OCK base image
		virsh vol-create --pool $POOL --file <(cat << EOF
<volume type='file'>
  <name>$BASE_IMAGE</name>
  <capacity unit='G'>30</capacity>
  <target>
    <format type='qcow2'/>
    <permissions>
      <mode>0640</mode>
      <owner>107</owner>
      <group>107</group>
    </permissions>
    <compat>1.1</compat>
    <features/>
  </target>
</volume>
EOF
)
		virsh vol-upload --pool $POOL --vol $BASE_IMAGE --file $BASE_IMAGE --sparse
	done

	# Configure a VXLAN on the OVS bridge that tunnels to the other host
	ssh $USER@$HOST1 "
		sudo ovs-vsctl add-port ovsbr0 vx_node2 -- set interface vx_node2 type=vxlan options:remote_ip=$(getent ahostsv4 ovs2 | head -1 | cut -d' ' -f1)
		sudo ip addr add dev ovsbr0 10.0.1.2/24
		true
	"

	# And vice-versa
	ssh $USER@$HOST2 "
		sudo ovs-vsctl add-port ovsbr0 vx_node1 -- set interface vx_node1 type=vxlan options:remote_ip=$(getent ahostsv4 ovs1 | head -1 | cut -d' ' -f1)
		sudo ip addr add dev ovsbr0 10.0.1.3/24
		true
	"


	# Install and configure NGINX as a reverse proxy.  It will talk to the
	# control plane nodes to allow access to the cluster from hosts that are
	# not part of the VXLAN.  Given that this is just a simple example, no
	# attempt is made to create an HA configuration for NGINX.  It is installed
	# on a single host and there is no virtual IP or similar HA configuration.
	# However, it is possible to imagine what such a configuration might
	# look like.
	ssh $USER@$HOST1 sudo dnf install -y nginx
	ssh $USER@$HOST1 sudo tee /etc/nginx/nginx.conf << EOF
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;
events {
  worker_connections 2048;
}
stream {
  upstream backend1 {
    server 10.0.1.10:6443;
  }
  server {
    listen 6443;
    listen [::]:6443;
    proxy_pass backend1;
  }
}
EOF

	# By default on Oracle Linux, NGINX is not able to listen on port 6443
	# nor is it allowed to make outbound connections.  Both of those things
	# need to be changed for this NGINX configuration to work.
	ssh $USER@$HOST1 sudo semanage port -a -t http_port_t -p tcp 6443
	ssh $USER@$HOST1 sudo setsebool -P httpd_can_network_connect 1
	ssh $USER@$HOST1 sudo systemctl enable --now nginx.service

	# Kubernetes has a hard requirement on DNS.  Well that's not entirely
	# true.  There is a hard requirement on a /etc/resolv.conf file.
	# Still, if there is going to be a resolv.conf then it may as well
	# work.  Configure DNSMasq on one of the hosts to resolv DNS queries
	# that originate from the VXLAN.  Again, this is not HA.  Again, one
	# can imagine setting this up on multiple hosts and configuring the
	# resolv.conf to match.
	ssh $USER@$HOST1 sudo tee /etc/dnsmasq.conf << EOF
interface=ovsbr0
bind-interfaces
EOF
	ssh $USER@$HOST1 sudo systemctl enable --now dnsmasq.service


	# To be able to reach addresses outside the VXLAN a gateway
	# is needed.  Arbitrarily choose one host to act as that
	# gateway.  Use NAT to avoid having to deal with actual
	# routing and subnet conflicts.
	ssh $USER@$HOST1 "
		sudo iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
		sudo iptables -A FORWARD -i ens3 -o ovsbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
		sudo iptables -A FORWARD -i ovsbr0 -o ens3 -j ACCEPT
	"
fi

# In this example there is no DHCP server.  Networking must be manually
# configured.  Create an additional ignition configuration that sets up all
# the static network configuration.  The resolv.conf points to the DNSMasq
# server, the hostname is set to the node name, and a network interface is
# set up.  Additional stuff can be added here as required/desired.
#
# Notice that the MTU is set to 1450.  VXLAN has a 50 byte overhead for
# IPv4.  The OVS bridge has an MTU of 1500.  In order to avoid fragmentation,
# the MTU on the cluster nodes needs to be 50 bytes smaller than that.
# 1500 minus 50 is 1450.
cat > extraIgnition.yaml << EOF
variant: fcos
version: 1.5.0
storage:
  files:
  - path: /etc/resolv.conf
    contents:
      inline: |
        nameserver 10.0.1.2
  - path: /etc/hostname
    contents:
      inline: $NAME-control-plane-1
  - path: /etc/sysconfig/network-scripts/ifcfg-enp1s0
    contents:
      inline: |
        BOOTPROTO=none
        DEVICE=enp1s0
        NAME=enp1s0
        ONBOOT=yes
        TYPE=Ethernet
        IPADDR=10.0.1.10
        GATEWAY=10.0.1.2
        NETMASK=255.255.255.0
        BROADCAST=10.0.1.255
        MTU=1450
EOF

# A simple cluster configuration file is used to instantiate cluster nodes.
# Given that the cluster uses the BYO provider, the configuration is simple.
# The complex stuff has already been done as part of setting up the environment.
cat > clusterConfig.yaml << EOF
loadBalancer: $(getent ahostsv4 ovs1 | head -1 | cut -d' ' -f1)
provider: byo
providers:
  byo:
    networkInterface: enp1s0
    automaticTokenCreation: true
extraIgnition: extraIgnition.yaml
EOF

# Set up some control plane nodes
# - Create a volume
# - Create the ignition
# - Create the domain
# - Start the domain

# Start a cluster by creating a control plane node on the first host.
NODE_NAME="$NAME-control-plane-1"
ocne cluster start -C $NAME -c clusterConfig.yaml > $NODE_NAME.ign

export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST1/system"

# Get the path to the base image volume so that a layered volume can be made.
# This assumes that the store pool is a "dir" pool, which is true for this example.
VOLUME_PATH=$(virsh vol-path --pool images "$BASE_IMAGE")
export POOL_PATH=$(dirname "$VOLUME_PATH")

# Create the volumes required for the node.  The first volume is the root disk.
# It layered on top of the base image.  The second volume is the ignition file
# that was generated as part of cluster start.
virsh vol-create $POOL <(cat << EOF
<volume type='file'>
  <name>$NODE_NAME.qcow2</name>
  <capacity unit='G'>50</capacity>
  <target>
    <format type='qcow2'/>
    <permissions>
      <mode>0640</mode>
      <owner>107</owner>
      <group>107</group>
    </permissions>
    <compat>1.1</compat>
    <clusterSize unit='B'>65536</clusterSize>
    <features/>
  </target>
  <backingStore>
    <path>$VOLUME_PATH</path>
    <format type='qcow2'/>
  </backingStore>
</volume>
EOF
)

virsh vol-create $POOL <(cat << EOF
<volume type='file'>
  <name>$NODE_NAME.ign</name>
  <capacity unit='bytes'>$(wc -c $NODE_NAME.ign | cut -d' ' -f1)</capacity>
  <target>
    <format type='raw'/>
    <permissions>
      <mode>0640</mode>
      <owner>107</owner>
      <group>107</group>
    </permissions>
    <compat>1.1</compat>
    <clusterSize unit='B'>65536</clusterSize>
    <features/>
  </target>
</volume>
EOF
)
virsh vol-upload --pool $POOL --file $NODE_NAME.ign --vol $NODE_NAME.ign
IGNITION_PATH=$(virsh vol-path --pool $POOL $NODE_NAME.ign)

# Create the domain.
virsh define <(cat << EOF
<domain type='kvm' id='1' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${NODE_NAME}</name>
  <memory unit='KiB'>4194304</memory>
  <currentMemory unit='KiB'>4194304</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <resource>
    <partition>/machine</partition>
  </resource>
  <os firmware='efi'>
    <type arch='$(uname -m)' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <smm state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <feature policy='disable' name='pdpe1gb'/>
  </cpu>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source pool='${POOL}' volume='${NODE_NAME}.qcow2' index='1'/>
      <target dev='sda' bus='scsi'/>
      <alias name='scsi0-0-0-0'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'>
      <alias name='scsi0'/>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </controller>
    <interface type='network'>
      <source network='ovs'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <audio id='1' type='none'/>
    <memballoon model='virtio'>
      <alias name='balloon0'/>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <alias name='rng0'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </rng>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-fw_cfg'/>
    <qemu:arg value='name=opt/com.coreos/config,file=${IGNITION_PATH}'/>
  </qemu:commandline>
  <seclabel type='dynamic' model='selinux' relabel='yes'>
    <label>system_u:system_r:svirt_t:s0:c334,c524</label>
    <imagelabel>system_u:object_r:svirt_image_t:s0:c334,c524</imagelabel>
  </seclabel>
  <seclabel type='dynamic' model='dac' relabel='yes'>
    <label>+107:+107</label>
    <imagelabel>+107:+107</imagelabel>
  </seclabel>
</domain>
EOF
)

virsh start $NODE_NAME


# Give the node some time to come up.
sleep 120

# Install the core cluster components.
ocne cluster start -C $NAME -c clusterConfig.yaml --auto-start-ui false

export KUBECONFIG=$(ocne cluster show -C $NAME)

# Make a worker node on the other host
export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST2/system"

export NODE_NAME=$NAME-worker-1

VOLUME_PATH=$(virsh vol-path --pool images "$BASE_IMAGE")
export POOL_PATH=$(dirname "$VOLUME_PATH")

# Update the additional ignition configuration with a unique IP and hostname.
sed -i 's/10.0.1.10/10.0.1.11/' extraIgnition.yaml
sed -i "s/$NAME-control-plane-1/$NAME-worker-1/" extraIgnition.yaml

# Generate the ignition file for the worker node
ocne cluster join --kubeconfig $KUBECONFIG -c clusterConfig.yaml > $NODE_NAME.ign

# Create a layered root disk
virsh vol-create $POOL <(cat << EOF
<volume type='file'>
  <name>$NODE_NAME.qcow2</name>
  <capacity unit='G'>50</capacity>
  <target>
    <format type='qcow2'/>
    <permissions>
      <mode>0640</mode>
      <owner>107</owner>
      <group>107</group>
    </permissions>
    <compat>1.1</compat>
    <clusterSize unit='B'>65536</clusterSize>
    <features/>
  </target>
  <backingStore>
    <path>$VOLUME_PATH</path>
    <format type='qcow2'/>
  </backingStore>
</volume>
EOF
)

# Upload the ignition file
virsh vol-create $POOL <(cat << EOF
<volume type='file'>
  <name>$NODE_NAME.ign</name>
  <capacity unit='bytes'>$(wc -c $NODE_NAME.ign | cut -d' ' -f1)</capacity>
  <target>
    <format type='raw'/>
    <permissions>
      <mode>0640</mode>
      <owner>107</owner>
      <group>107</group>
    </permissions>
    <compat>1.1</compat>
    <clusterSize unit='B'>65536</clusterSize>
    <features/>
  </target>
</volume>
EOF
)
virsh vol-upload --pool $POOL --file $NODE_NAME.ign --vol $NODE_NAME.ign
IGNITION_PATH=$(virsh vol-path --pool $POOL $NODE_NAME.ign)

# Create the domain.
virsh define <(cat << EOF
<domain type='kvm' id='1' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${NODE_NAME}</name>
  <memory unit='KiB'>4194304</memory>
  <currentMemory unit='KiB'>4194304</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <resource>
    <partition>/machine</partition>
  </resource>
  <os firmware='efi'>
    <type arch='$(uname -m)' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <smm state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <feature policy='disable' name='pdpe1gb'/>
  </cpu>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source pool='${POOL}' volume='${NODE_NAME}.qcow2' index='1'/>
      <target dev='sda' bus='scsi'/>
      <alias name='scsi0-0-0-0'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'>
      <alias name='scsi0'/>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </controller>
    <interface type='network'>
      <source network='ovs'/>
      <model type='virtio'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <audio id='1' type='none'/>
    <memballoon model='virtio'>
      <alias name='balloon0'/>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <alias name='rng0'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </rng>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-fw_cfg'/>
    <qemu:arg value='name=opt/com.coreos/config,file=${IGNITION_PATH}'/>
  </qemu:commandline>
  <seclabel type='dynamic' model='selinux' relabel='yes'>
    <label>system_u:system_r:svirt_t:s0:c334,c524</label>
    <imagelabel>system_u:object_r:svirt_image_t:s0:c334,c524</imagelabel>
  </seclabel>
  <seclabel type='dynamic' model='dac' relabel='yes'>
    <label>+107:+107</label>
    <imagelabel>+107:+107</imagelabel>
  </seclabel>
</domain>
EOF
)

virsh start $NODE_NAME

# Let the node come up and join the cluster
sleep 120

# Et voila!
kubectl get node

# install stuff
set -x
set -e

SETUP=
USER=opc
HOST1=ovs1
HOST2=ovs2
VERSION=1.31
POOL=images
NAME=ovs

BASE_IMAGE=boot-$VERSION.qcow2

if [ -n "$SETUP" ]; then
	# Extract Image
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
		ssh $USER@$host sh -c "
			dnf install -y oracle-ovirt-release-el8
			dnf config-manager --enable ol8_kvm_appstream ovirt-4.4 ovirt-4.4-extra
			dnf install -y openvswitch
			dnf module reset -y virt:ol
			dnf module install -y virt:kvm_utils3/common

			# start services
			systemctl enable --now libvirtd.service
			systemctl enable --now openvswitch.service

			# create networks - ovs stuff
			ovs-vsctl add-br ovsbr0
			ip link set ovsbr0 up
			usermod -a -G libvirt,qemu $USER
		"

		# create networks - libvirt stuff
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

		# Upload base imagea
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

	# configure vxlan on node 1
	ssh $USER@$HOST1 sh -c "
		ovs-vsctl add-port ovsbr0 vx_node2 -- set interface vx_node2 type=vxlan options:remote_ip=$(getent ahostsv4 ovs2 | head -1 | cut -d' ' -f1)
		ip addr add dev ovsbr0 10.0.1.2/24
	"

	# Configure vxlan on node 2
	ssh $USER@$HOST2 sh -c "
		ovs-vsctl add-port ovsbr0 vx_node1 -- set interface vx_node1 type=vxlan options:remote_ip=$(getent ahostsv4 ovs1 | head -1 | cut -d' ' -f1)
		ip addr add dev ovsbr0 10.0.1.3/24
	"


	# Install and configure NGINX on one host to use as a load balancer
	ssh $USER@$HOST1 sudo dnf install -y nginx
	ssh $USER@$HOST1 sudo sh -c "cat > /etc/nginx/nginx.conf" << EOF
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

	# Allow NGINX to bind to port 6443 and initiate outbound connections
	ssh $USER@$HOST1 sudo semanage port -a -t http_port_t -p tcp 6443
	ssh $USER@$HOST1 sudo setsebool -P httpd_can_network_connect 1
	ssh $USER@$HOST1 sudo systemctl enable --now nginx.service

	# There is also a requirement for DNS
	ssh $USER@$HOST sudo sh -c "cat > /etc/dnsmasq.conf" << EOF
interface=ovsbr0
bind-interfaces
EOF
	ssh $USER@$HOST sudo systemctl enable --now dnsmasq.service
fi

# Create an extra ignition file
cat > extraIgnition.yaml << EOF
variant: fcos
version: 1.5.0
storage:
  files:
  - path: /etc/resolv.conf
    contents:
      inline: |
        nameserver 10.0.1.3
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
        GATEWAY=10.0.1.3
        NETMASK=255.255.255.0
        BROADCAST=10.0.1.255
        MTU=1450
passwd:
  users:
    - name: dkrasins
      password_hash: "$6$ocne$6ReF22fGSN6cyepwGW.7hwBdQw7/Ho/PYXSeT3zPc0bPycWXY4wl1uWFG47FESG8kdA3vk6PG9mAElcI2stVT1"
      groups:
        - wheel
      ssh_authorized_keys:
        - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDB/ycCcGJRdCrYJRB5YebGsk17zm/IadzqfzOX768djvAjNHOhD9/kag7YqOTq7PDzF8c2jIDObzVA9gHfblM/f9dBtVf2aF/ukFrN3Va1sftMYyRotVxljQkvppSV5y0GC+lI/EeHwKcnk5mT7MnSUECDWSQ5RACy6AITrFzfR4cxhhOpkK3TTKKg9iSO62PyyLi7g031Dk8x1RVqk+3H/VKSaL8ikLcfZyXyeKcrpYD3AWrswn/GVHrh/BjI+k7NkwhWa03fOEqq2D+eqC2OSok2nQyNMT95kWvvx6TDlBIPPw3yz9ha7qmII6v95Cg9v2yUO4KQ86/wKRpP8DpeqFe+peCVM7/P4PdVqN3JNk+6Bq1rjhiYWwY6EI4riQLp0e+KnUnZwpLi+zPRZsoffSvHcFx/riWN3a0+Xm2uKg9MGAXrdwTkrcg/gj8RjvRqiaUWf/PEtMU+0G9xa8ZsCpuVa8pM/Xd95n5LaWS+TIOfR+sFxhw8XNARXAomZJc= opc@dkrasins-ol9-new
EOF

# Create a cluster configuration file
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

ocne cluster start -C $NAME -c clusterConfig.yaml --auto-start-ui false

export KUBECONFIG=$(ocne cluster show -C $NAME)

# Make a worker node on the other host
export LIBVIRT_DEFAULT_URI="qemu+ssh://$USER@$HOST2/system"

export NODE_NAME=$NAME-worker-1

VOLUME_PATH=$(virsh vol-path --pool images "$BASE_IMAGE")
export POOL_PATH=$(dirname "$VOLUME_PATH")

sed -i 's/10.0.1.10/10.0.1.11/' extraIgnition.yaml
sed -i "s/$NAME-control-plane-1/$NAME-worker-1/" extraIgnition.yaml

ocne cluster join --kubeconfig $KUBECONFIG -c clusterConfig.yaml > $NODE_NAME.ign

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

# Let the node come up and join the cluster
sleep 120

kubectl get node

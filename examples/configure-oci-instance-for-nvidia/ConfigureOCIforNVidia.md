# Configure OCI Instance for Installing Nvidia CUDA Driver

Example instructions of how to configure an OCI instance for installing the Nvidia CUDA driver.

## Create an OCI Instance

Create an OCI instance with the following settings:
* Image - Oracle Linux 8
* Shape - Bare Metal BM.GPU.A10.4
* Increase the default boot volume size to 150GB
* Networking
  * Primary Network: Compartment Networks, VCN: <your VCN>
  * Subnet: Compartment Networks, Subnet: <your Subnet>
  * Paste in ssh keys

## Pre-Install Actions

### Expand Boot Volume Size
```shell
sudo /usr/libexec/oci-growfs
```

### Add proxy setup to login
```
vi ~/.bashrc
export http_proxy=<proxy value>
export https_proxy=<proxy value>
export no_proxy=<proxy value>
export HTTP_PROXY=<proxy value>
export HTTPS_PROXY=<proxy value>
export NO_PROXY=<proxy value>
```

Log out and back in.

### Configure Install Repos
OL8
```shell
sudo dnf install -y oracle-epel-release-el8
sudo dnf config-manager --enable ol8_developer_EPEL
sudo dnf config-manager --set-enabled ol8_codeready_builder
sudo dnf install -y git cmake gcc-toolset-11-gcc gcc-toolset-11
sudo dnf install -y "kernel-uek-devel-$(uname -r)"
```

OL9
```shell
sudo dnf install -y oracle-epel-release-el9
sudo dnf config-manager --enable ol9_developer_EPEL
sudo dnf config-manager --set-enabled ol9_codeready_builder
sudo dnf install -y git cmake gcc-toolset-11-gcc gcc-toolset-11
sudo dnf install -y "kernel-uek-devel-$(uname -r)"
```

### Verify You Have a CUDA-Capable GPU
```shell
lspci | grep -i nvidia
```

### Verify You Have a Supported Version of Linux
```shell
hostnamectl
```

### Verify the System Has gcc Installed
```shell
scl enable gcc-toolset-11 bash
gcc --version
```

#### Check the Installation
Check if `nouveau` module enable, if so remove it
```shell
sudo dmesg | less
lsmod | grep nouveau
sudo rmmod nouveau
```

## Installation

### CUDA Toolkit Installer
Install some dependencies required for installing the Nvidia driver.

OL8
```shell
wget https://developer.download.nvidia.com/compute/cuda/13.0.2/local_installers/cuda-repo-rhel8-13-0-local-13.0.2_580.95.05-1.x86_64.rpm
sudo rpm -i cuda-repo-rhel8-13-0-local-13.0.2_580.95.05-1.x86_64.rpm
sudo dnf clean all
sudo dnf -y install cuda-toolkit-13-0
```
OL9
```shell
wget https://developer.download.nvidia.com/compute/cuda/13.0.2/local_installers/cuda-repo-rhel9-13-0-local-13.0.2_580.95.05-1.x86_64.rpm
sudo rpm -i cuda-repo-rhel9-13-0-local-13.0.2_580.95.05-1.x86_64.rpm
sudo dnf clean all
sudo dnf -y install cuda-toolkit-13-0
```

### Clone and Build NVIDIA Linux Open GPU Kernel Module Source
```shell
git clone https://github.com/NVIDIA/open-gpu-kernel-modules.git
cd open-gpu-kernel-modules
make modules -j$(nproc)
sudo make modules_install
sudo modprobe nvidia
lsmod | grep nvidia
```

### Driver Installer
The driver installation includes `nvidia-smi`.

To install the open kernel module flavor:
```shell
sudo dnf -y module install nvidia-driver:open-dkms
```

To install the proprietary kernel module flavor: (which I did not do)
```shell
sudo dnf -y module install nvidia-driver:latest-dkms
```

### Update PATH
Update path, then log out and back in

```text
vi ~/.bashrc
export PATH=${PATH}:/usr/local/cuda-13.0/bin
```

## Verify the Installation

### Quick Sanity Test
```shell
sudo nvidia-smi

nvidia-smi
Mon Nov  3 12:54:39 2025       
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.95.05              Driver Version: 580.95.05      CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA A10                     Off |   00000000:17:00.0 Off |                    0 |
|  0%   31C    P0             54W /  150W |       0MiB /  23028MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+
|   1  NVIDIA A10                     Off |   00000000:31:00.0 Off |                    0 |
|  0%   29C    P0             51W /  150W |       0MiB /  23028MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+
|   2  NVIDIA A10                     Off |   00000000:B1:00.0 Off |                    0 |
|  0%   31C    P0             52W /  150W |       0MiB /  23028MiB |      2%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+
|   3  NVIDIA A10                     Off |   00000000:CA:00.0 Off |                    0 |
|  0%   31C    P0             52W /  150W |       0MiB /  23028MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+

```

### ollama

```text
sudo curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl start ollama

# Add proxies to ollama.service
sudo su -
cd /etc/systemd/system
vi ollama.service
Environment="<proxy value>"
Environment="<proxy value>"

systemctl daemon-reload
systemctl restart ollama.service
control-d

ollama run qwen3:0.6b
ollama pull gpt-oss:20b
ollama run gpt-oss:20b
```

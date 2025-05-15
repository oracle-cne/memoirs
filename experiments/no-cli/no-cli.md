# A Templated Installation Without the CLI

In some environments, it not feasible to use the `ocne` command prior to
provisioning cluster nodes but some amount of the configuration it generates
is required.  One example is a cluster that uses a Virtual IP for the Kubernetes
API Server endpoint.  In this case, it can be useful to generate an ignition
template and edit that file to suit the needs of the deployment.

# Generating a Template

To generate the template, first create a cluster configuration file using the
BYO provider.  From that, generate an ignition file.  That ignition file will
contain some information that cannot be re-used from cluster to cluster, notably
the root certificate authority keys that form the trust anchor for Kubernetes.
Re-using that PKI is Bad because it will allow a authentication between clusters.
Once that information is removed, it may be necessary to decode some of the
files encoded within the ignition file itself.  Any fields that need to be
edited can then be edited.  In some cases that may involve replacing character
sequences with strings appropriate for the templating lanuage being used.  In
others that may involve using tools like `jq`.  It may be worth re-encoding the
files before using the ignition configuration to start a node.  All that matters
is that the result of any edits and templating is a valid ignition file that
does what is required.

Note that once the PKI information is deleted, the kubeconfig file for the
cluster is no longer valid.  It should be deleted.

Generate an ignition file to templatize.

```
$ ocne cluster start -c clusterConfig.yaml > init.ign
```

Now delete the cluster to clean up the kubeconfig.

```
$ ocne cluster delete -c clusterConfig.yaml
```

In this case, the virtual IP field is what is being customized.  In the cluster
configuration file, it is set to `192.168.122.75`.  The files that contain that
address are `/etc/keepalived/keepalived.conf`, `/etc/keepalived/keepalived.conf.tmpl`
and `/etc/kubernetes/kubeadm.conf`.

In the existing file, those fields are encoded
```
$ jq ".storage.files[] | select(.path == \"/etc/kubernetes/kubeadm.conf\").contents.source" < init.ign 
"data:;base64,H4sIAAAAAAAC/5xTy47rNgzd+yv0A37Gj0S7YDqLQdtpMBl0UxSFLDEOEUUyKDoz6dcXjp1Mg3txcRFpJx4eHR6Sqsc/gQJ6J8VhaEGZY3JYhgR9espbYLWIDuiMFC8O+cm7HXYDKUbvIuu1suvNy7MzvUfHMhJCCGVOQIwB1sYQhCDF6x+/PP/zsrlEW3Rm44mlqMuyjJw38AYdBp44J4pRhwV+/mRSa+rC9DqeER9jf885HrYhPqKLT9da5qLef9vmxQ2lrpKy5HK/AgPvPeG/FxHx0RuQYm0/1DmsrfUfN9zJ2+EIcW+HDl1skKRIT4pSi206q04nzAQJl0xW6DhI8dffkR692aFWDL/CWYpCN9lilRVaNVkOTQaqWK6aumrLdmf0rijaQtfLqipgZ6qybpumzaBaZm2tctOqJgoH7Dd7FWB2KR6L9O6iJu7Jf57vnrUnMLOsWPQEO4vdnqNesd5fOQwSaPZ0liIF1qnXDlKvD+mMiqI4jqOfnpwnOwQGuh8e1eMW6AQ0fQnf9vrHLdXeMXlrgX5XTnUP8wS9BzPYh/Md8IenA7puyghAJ9SwHVoHLEWeJat6HLV0HsPem//FirKcgnWER9XBG/Q+4GT9WKFCBxTTtCHnxJPSFhLtj6m32kE0+k4OGMKtFXmyyJPs6s/GKge3BRX5qkjyepnkRZE0lazLchEBazNpvyz0V+EPKbpLfledFIukSvLqFviOw5e/MTC4+AhMqEM8kA1S7Jl7mabztspiscxvST0APQHxdv06rZZxM+XDur8064EIHEf/BQAA///hzAUGHgUAAA=="

jq ".storage.files[] | select(.path == \"/etc/keepalived/keepalived.conf\").contents.source" < init.ign 
"data:;base64,H4sIAAAAAAAC/1yQT4vbMBDF7/oUj/TuxAb3zzFtUyjNodAmV6FI43iIkIQ09hKWfPfFibNZchOa3zze/NTRx4Px2lFX8KqAHAehrNlhu/+nf272m60CKJiDJ11s5iS6kB0yy1ld1Jhzmr9he7InbRIXyiPla9w8WixJ7PJElIznkdzyia1Kv1AAB6E8Go9WAS/Ex16wwieswAWByJFDFzM4FDHBEiRCsgmFhWMAB5jgEAdB7PBrvdv+RxEjpIDOeI96NV3IhdDcu79H7X/r+lZ52sD39Y8/u7/3Tp2xBAqpLlPCyFkG4/XDVVsrIGWOkxa0EzQEtqaITnRVoYDLh1VOxrlM5SYdqL81Vf35a1U3TfWlnWHJxp7udm/ck7cZDFG4O+NZ8uOpr0dVpVcX9RYAAP//Smk8k/MBAAA="

$ jq ".storage.files[] | select(.path == \"/etc/ocne/keepalived.conf.tmpl\").contents.source" < init.ign 
"data:;base64,H4sIAAAAAAAC/1yQzarbMBCF93qKw+3eiQ3uz/K2daE0i0vTZCsUaRwPEZKQxi6h5N2LE6cp2QnNN4cznzr6eDBeO+oL/iggx1Eoa3bY7Lf6a7fvNgqgYA6edLGZk+hCdswsZ3VRU85p+YYdyJ60SVwoT5SvccvoZUViVyeiZDxP5FZPbFWGFwVwEMqT8WgV8Jv4OAjWeIc1uCAQOXLoYwaHIiZYgkRINqGwcAzgABMc4iiIPb697ja/UMQIKaA33qNezxdyITT37v+i9t91fas8b+Dz65cfu7d7p95YAoVUlzlh4iyj8frhqq0VkDLHWQvaGRoDW1NEJ7qqeOu6n1sFXP7b52Scy1Ru5oH6U1PV7z9WddNUH9oFlmzs6a74xj3JW8AQhfsznk0/nvp6WVUGdVF/AwAA//+MZvwn+AEAAA=="
```

This script finds those fields and decodes them, updating the ignition configuration with the decoded values.

```
$ sh make-template.sh -i init.ign > init.ign.tmpl
```

Notice that they are now decoded, and contain the virtual IP address.

```
$ jq ".storage.files[] | select(.path == \"/etc/ocne/keepalived.conf.tmpl\").contents.source" < init.ign.tmpl 
"data:,%0Aglobal_defs%20%7B%0A%20%20router_id%20LVS_DEVEL%0A%20%20enable_script_security%0A%7D%0Avrrp_script%20check_apiserver%20%7B%0A%20%20script%20%22%2Fetc%2Fkeepalived%2Fcheck_apiserver.sh%22%0A%20%20interval%205%0A%20%20weight%200%20%23%200%20is%20needed%20for%20instance%20to%20transition%20in%20and%20out%20of%20FAULT%20state%0A%20%20fall%2010%0A%20%20rise%202%0A%7D%0Avrrp_instance%20VI_1%20%7B%0A%20%20state%20BACKUP%0A%20%20interface%20enp1s0%0A%20%20virtual_router_id%2051%0A%20%20priority%2050%0A%20%20unicast_peer%20%7B%0APEERS%0A%20%20%7D%0A%20%20virtual_ipaddress%20%7B%0A%20%20%20%20192.168.122.75%0A%20%20%7D%0A%20%20track_script%20%7B%0A%20%20%20%20check_apiserver%0A%20%20%7D%0A%20%20notify%20%2Fetc%2Fkeepalived%2Fkeepalived_state.sh%0A%7D"

$ jq ".storage.files[] | select(.path == \"/etc/ocne/keepalived.conf.tmpl\").contents.source" < init.ign.tmpl
"data:,%0Aglobal_defs%20%7B%0A%20%20router_id%20LVS_DEVEL%0A%20%20enable_script_security%0A%7D%0Avrrp_script%20check_apiserver%20%7B%0A%20%20script%20%22%2Fetc%2Fkeepalived%2Fcheck_apiserver.sh%22%0A%20%20interval%205%0A%20%20weight%200%20%23%200%20is%20needed%20for%20instance%20to%20transition%20in%20and%20out%20of%20FAULT%20state%0A%20%20fall%2010%0A%20%20rise%202%0A%7D%0Avrrp_instance%20VI_1%20%7B%0A%20%20state%20BACKUP%0A%20%20interface%20enp1s0%0A%20%20virtual_router_id%2051%0A%20%20priority%2050%0A%20%20unicast_peer%20%7B%0APEERS%0A%20%20%7D%0A%20%20virtual_ipaddress%20%7B%0A%20%20%20%20192.168.122.75%0A%20%20%7D%0A%20%20track_script%20%7B%0A%20%20%20%20check_apiserver%0A%20%20%7D%0A%20%20notify%20%2Fetc%2Fkeepalived%2Fkeepalived_state.sh%0A%7D"

$ jq ".storage.files[] | select(.path == \"/etc/kubernetes/kubeadm.conf\").contents.source" < init.ign.tmpl
"data:,apiVersion%3A%20kubeadm.k8s.io%2Fv1beta3%0Akind%3A%20InitConfiguration%0AlocalAPIEndpoint%3A%0A%20%20%20%20advertiseAddress%3A%20NODE_IP%0A%20%20%20%20bindPort%3A%206444%0AnodeRegistration%3A%0A%20%20%20%20kubeletExtraArgs%3A%0A%20%20%20%20%20%20%20%20node-ip%3A%20NODE_IP%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0A%20%20%20%20%20%20%20%20address%3A%200.0.0.0%0A%20%20%20%20%20%20%20%20authorization-mode%3A%20AlwaysAllow%0A%20%20%20%20%20%20%20%20volume-plugin-dir%3A%20%2Fvar%2Flib%2Fkubelet%2Fvolumeplugins%0A%20%20%20%20taints%3A%20%5B%5D%0AcertificateKey%3A%202c703902ca701e70ea289765b4bfdcf22b2c68552efd546b77b0e580b6a1dba7%0AskipPhases%3A%0A%20%20%20%20-%20addon%2Fkube-proxy%0A%20%20%20%20-%20addon%2Fcoredns%0A%20%20%20%20-%20preflight%0Apatches%3A%0A%20%20%20%20directory%3A%20%2Fetc%2Focne%2Fock%2Fpatches%0A%0A---%0AapiVersion%3A%20kubeadm.k8s.io%2Fv1beta3%0Akind%3A%20ClusterConfiguration%0AapiServer%3A%0A%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0AcontrollerManager%3A%0A%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0Ascheduler%3A%0A%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0Anetworking%3A%0A%20%20%20%20serviceSubnet%3A%2010.96.0.0%2F12%0A%20%20%20%20podSubnet%3A%2010.244.0.0%2F16%0AimageRepository%3A%20container-registry.oracle.com%2Folcne%0AkubernetesVersion%3A%201.31.0%0AcontrolPlaneEndpoint%3A%20192.168.122.75%3A6443%0Aetcd%3A%0A%20%20%20%20local%3A%0A%20%20%20%20%20%20%20%20imageRepository%3A%20container-registry.oracle.com%2Folcne%0A%20%20%20%20%20%20%20%20imageTag%3A%203.5.15%0A%20%20%20%20%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20%20%20%20%20listen-metrics-urls%3A%20http%3A%2F%2F0.0.0.0%3A2381%0A%20%20%20%20%20%20%20%20peerCertSANs%3A%20%5B%5D%0Adns%3A%0A%20%20%20%20imageRepository%3A%20container-registry.oracle.com%2Folcne%0A%20%20%20%20imageTag%3A%20current"
```

From here, the template can be updated.  Replace the virtual IP address of `192.168.122.75` with `192.168.122.200`.

```
$ grep 192.168.122.200 < init-new-vip.ign
          "source": "data:,apiVersion%3A%20kubeadm.k8s.io%2Fv1beta3%0Akind%3A%20InitConfiguration%0AlocalAPIEndpoint%3A%0A%20%20%20%20advertiseAddress%3A%20NODE_IP%0A%20%20%20%20bindPort%3A%206444%0AnodeRegistration%3A%0A%20%20%20%20kubeletExtraArgs%3A%0A%20%20%20%20%20%20%20%20node-ip%3A%20NODE_IP%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0A%20%20%20%20%20%20%20%20address%3A%200.0.0.0%0A%20%20%20%20%20%20%20%20authorization-mode%3A%20AlwaysAllow%0A%20%20%20%20%20%20%20%20volume-plugin-dir%3A%20%2Fvar%2Flib%2Fkubelet%2Fvolumeplugins%0A%20%20%20%20taints%3A%20%5B%5D%0AcertificateKey%3A%202c703902ca701e70ea289765b4bfdcf22b2c68552efd546b77b0e580b6a1dba7%0AskipPhases%3A%0A%20%20%20%20-%20addon%2Fkube-proxy%0A%20%20%20%20-%20addon%2Fcoredns%0A%20%20%20%20-%20preflight%0Apatches%3A%0A%20%20%20%20directory%3A%20%2Fetc%2Focne%2Fock%2Fpatches%0A%0A---%0AapiVersion%3A%20kubeadm.k8s.io%2Fv1beta3%0Akind%3A%20ClusterConfiguration%0AapiServer%3A%0A%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0AcontrollerManager%3A%0A%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0Ascheduler%3A%0A%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20tls-min-version%3A%20VersionTLS12%0Anetworking%3A%0A%20%20%20%20serviceSubnet%3A%2010.96.0.0%2F12%0A%20%20%20%20podSubnet%3A%2010.244.0.0%2F16%0AimageRepository%3A%20container-registry.oracle.com%2Folcne%0AkubernetesVersion%3A%201.31.0%0AcontrolPlaneEndpoint%3A%20192.168.122.200%3A6443%0Aetcd%3A%0A%20%20%20%20local%3A%0A%20%20%20%20%20%20%20%20imageRepository%3A%20container-registry.oracle.com%2Folcne%0A%20%20%20%20%20%20%20%20imageTag%3A%203.5.15%0A%20%20%20%20%20%20%20%20extraArgs%3A%0A%20%20%20%20%20%20%20%20%20%20%20%20listen-metrics-urls%3A%20http%3A%2F%2F0.0.0.0%3A2381%0A%20%20%20%20%20%20%20%20peerCertSANs%3A%20%5B%5D%0Adns%3A%0A%20%20%20%20imageRepository%3A%20container-registry.oracle.com%2Folcne%0A%20%20%20%20imageTag%3A%20current",
          "source": "data:,%0Aglobal_defs%20%7B%0A%20%20router_id%20LVS_DEVEL%0A%20%20enable_script_security%0A%7D%0Avrrp_script%20check_apiserver%20%7B%0A%20%20script%20%22%2Fetc%2Fkeepalived%2Fcheck_apiserver.sh%22%0A%20%20interval%205%0A%20%20weight%200%20%23%200%20is%20needed%20for%20instance%20to%20transition%20in%20and%20out%20of%20FAULT%20state%0A%20%20fall%2010%0A%20%20rise%202%0A%7D%0Avrrp_instance%20VI_1%20%7B%0A%20%20state%20BACKUP%0A%20%20interface%20enp1s0%0A%20%20virtual_router_id%2051%0A%20%20priority%2050%0A%20%20unicast_peer%20%7B%0A%0A%20%20%7D%0A%20%20virtual_ipaddress%20%7B%0A%20%20%20%20192.168.122.200%0A%20%20%7D%0A%20%20track_script%20%7B%0A%20%20%20%20check_apiserver%0A%20%20%7D%0A%20%20notify%20%2Fetc%2Fkeepalived%2Fkeepalived_state.sh%0A%7D",
          "source": "data:,%0Aglobal_defs%20%7B%0A%20%20router_id%20LVS_DEVEL%0A%20%20enable_script_security%0A%7D%0Avrrp_script%20check_apiserver%20%7B%0A%20%20script%20%22%2Fetc%2Fkeepalived%2Fcheck_apiserver.sh%22%0A%20%20interval%205%0A%20%20weight%200%20%23%200%20is%20needed%20for%20instance%20to%20transition%20in%20and%20out%20of%20FAULT%20state%0A%20%20fall%2010%0A%20%20rise%202%0A%7D%0Avrrp_instance%20VI_1%20%7B%0A%20%20state%20BACKUP%0A%20%20interface%20enp1s0%0A%20%20virtual_router_id%2051%0A%20%20priority%2050%0A%20%20unicast_peer%20%7B%0APEERS%0A%20%20%7D%0A%20%20virtual_ipaddress%20%7B%0A%20%20%20%20192.168.122.200%0A%20%20%7D%0A%20%20track_script%20%7B%0A%20%20%20%20check_apiserver%0A%20%20%7D%0A%20%20notify%20%2Fetc%2Fkeepalived%2Fkeepalived_state.sh%0A%7D",
```

This ignition can be fed into a new control plane node to create a cluster with a standard configuration but a unique virtual IP.

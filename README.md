# helm-sandbox
Tyk sandbox created with tyk helm charts

## Note that this is not a product in any way, it has no support or warranty of any type and the whole repo could be removed at any time


### I use this tool to deploy Tyk for testing purposes. The notes documented here are meant as an aid to me and to my fellow team members who might want to use it

### What the helm sandbox tries to do.

I wanted a tool that allowed me to deploy Tyk using the Tyk helm charts in a quick and easy way. I also wanted to be able to have multiple deployments at once so I could work on different issues at the same time.

Here is the help from the `hsbctl` (helm sandbox control) command. It should provide enough of a reminder so that someone who already knows what they're doing can be reminded of the exact command
```
$ hsbctl
[USAGE]: hsbctl create -v <tyk version> -t <namespace description>
      Create a tyk instance in a namespace sandbox with the version given as a tag with -v
      -C The chart to deploy. Defaults to tyk-stack
         Supported charts are:
         tyk-stack
         tyk-control-plane
         tyk-data-plane
      -D The size of the allocated Mongo or PG storage in Gi (default: 5Gi)
      -E A file to read environment variables from and add them all deployments
      -g The number of gateway replicas to run
      -h Enable https on gateways
      -K MDCB api key
         Used by data plane only and only when the control plane isn't a sandbox in the cluster
         Incompatible with -R
      -M MDCB connection string.
         Used by data plane only and only when the control plane isn't a sandbox in the cluster
         Incompatible with -R
      -N Use the given namespace name rather than the next available sandbox
         Useful when there's a need to import apis and policy YAML with set namespace
      -O MDCB rpc_key (orgid)
         Used by data plane only and only when the control plane isn't a sandbox in the cluster
         Incompatible with -R
      -p Deploy with postgres not mongo
      -P Deploy with EDP. (Implies -p)
      -R The remote control plane sandbox to use for a data plane deployment.
         Implies -C tyk-data-plane
      -r The size of the allocated redis control or data plane storage in Gi (default: 1Gi)
      -S Connect to MDCB over SSL
         Used by data plane only and only when the control plane isn't a sandbox in the cluster
         Incompatible with -R
      -s Enable MDCB synchroniser. Only valid with '-C tyk-control-plane' and '-C tyk-data-plane'
      -t Description of the sandbox namespace
      -V values.yaml file to use instead of other options. Note this overrides all other Tyk options
      -v Version tag. The file /home/pstubbs/code/helm-sandbox/tyk-versions.list contains the versions of each product used
hsbctl delete <sandbox namespace...>
      Delete the sandbox namespace given as a tag and all resources in it
hsbctl get <sandbox namespace...> [chart|description|dashboard|gateway|redis|redis-password|redis-port|release|key|mdcb|mongo|postgres|orgid|values]
      Print the requested detail in a way that's useful in another script
hsbctl init setup minikube ready to run sandboxes
hsbctl info <sandbox namespace...>
      Print info detailed info on sandbox namespaces
hsbctl logs <sandbox namespace...> <pod part name>
      Tails the logs of the first pod that matches 'pod part name' in the namespace
hsbctl modify <sandbox namespace> <deployment name> [-c count] [-v version]
      Modify deployment named to have a new number of pods and/or pods at the named version
      -c change the deployment to have the new number of pods
      -v rollout the named version into the pods. No checking of the version is done
         so make sure it's right
hsbctl monitor <sandbox namespace> <pod name>
      Print CPU and memory usage for the containers in the pod every 5s seconds
      operator: install the latest version of operator ready for contexts in sandbox namespaces
      To install another verions of operator set and export HSBX_OPERATOR_VERSION before invoking the command
hsbctl setup operator
hsbctl shell <sandbox namespace...> <pod part name>
      Spawns a shell into the pod. Mostly they are now distroless but the bastion can be used
hsbctl start start minikube and all namespaces
hsbctl version <sandbox namespace...>
      Shows the image version in each deployment in the namespace
```

### The config file
When the file `~/.tyk-sandbox` is present it is sourced by `hsbctl` during startup. This file provides environment variables that affect the behaviour of `hsbctl`

Here is a list of the environment variables and what they do
- `SBX_LICENSE` Set this to your dashboard/operator licence
- `SBX_MDCB_LICENSE` Set this to your MDCB licence
- `SBX_USER` The user email address to initialise the dashboard and EDP with
- `SBX_PASSWORD` Base 64 encoded password to set on the `$SBX_USER` account
- `K8S_DEPLOYMENT` The kubernetes deployment to use. It should be one of "minikube" or "k3s". Minikube is much more tested

### Where the plugin bundles are kept
A directory will be created in your home directory called `~/.tyk`. In it a subdirectory will be created for each version of Tyk deployed by `hsbctl`
This will be mounted into a container in the namespace of each deployment which runs a bundle server. The Tyk gateways will be deployed with the correct config to download bundles from that bundle server. The bundle server is called "bastion"

There is no support for delivering plugins without using a bundle

### The bastion server
A simple linux container based on the AlmaLinux UBI is provided. This is deployed into each namespace and allows shell access to use tools like curl etc. for diagnostic purposes
It also mounts `~/.tyk/pulgins` and runs a simple python web server so that bundles can be downloaded by gateways. The gateways in each deployment are already configured to use this bundle server

Shell access to the bastion can be obtained like this
```
$ hsbctl shell <hsanbox namespace name> shell
```
The `<hsanbox namespace name>` can be the full name like `hsandbox-1` or just the number `1`

## `hsandbox` commands in detail
### `init`
Depending on the value of `$K8S_DEPLOYMENT` this will either install and configure minikube or k3s. Minikube is the default.

The minikube deployment is more mature and a number of alterations are made to the deployment to ensure that the metrics server has metrics retained for 2 hours with a 1 minute granularity. It also works out how much memory the minikube deployment should be allowed. Along with a few other things. Have a read of the `setupMinikube` function for more details
`~/.kube/minikube-config` will be created with the correct config for minikube

The k3s deployment is less tested but has the advantage that it allows resources to be accessed from another machine.
`~/.kube/k3s-config` will be created with the correct config for k3s

**Note that it may be necessary to source your ~/.bashrc or set KUBECONFIG manually to access kubernetes**

### create
When creating a helm sandbox the deployed version is specified with `-v`. The versions of other components are read from a file delivered in the helm-sandbox repo called `tyk-versions.list`. The format of that file is documented within it.

#!/bin/bash

TAG=saintpeter/bastion-9:latest
SCRIPTNAME=$0
SCRIPTDIR=$(
  cd "$(dirname $SCRIPTNAME)"
  echo $PWD
)

cd $SCRIPTDIR

if sudo k3s ctr images list | grep -q bastion-9:latest ; then
  echo "[WARN]$TAG already registered in k3s"
  # it can be removed with 'sudo k3s ctr images remove $TAG'
else
  echo "[INFO]Building the bastion host image in k3s. Please be patient"
  if ! docker image list $TAG | grep -q $TAG; then
    docker build -t $TAG .
  fi
  docker save $TAG | sudo k3s ctr images import -
  echo "[INFO]Image $TAG is now available in k3s"
fi

# Pin the image so kubelet's image garbage collection never removes it when
# no pod is using it (it is local-only and cannot be re-pulled from a registry)
sudo k3s ctr -n k8s.io images label docker.io/$TAG io.cri-containerd.pinned=pinned >/dev/null
echo "[INFO]Image $TAG is pinned in k3s"

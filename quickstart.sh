#!/bin/bash

NAMESPACE="${1:-tyk}"
REDIS_YAML=$(mktemp /tmp/redis.yaml.XXXX)
MONGO_YAML=$(mktemp /tmp/mongo.yaml.XXXX)
TYK_YAML=$(mktemp /tmp/tyk-pro.yaml.XXXX)

trap 'rm -f $REDIS_YAML $MONGO_YAML $TYK_YAML' 0 1 2 3 15

if ! kubectl create namespace $NAMESPACE; then
  echo "[FATAL]Namespace $NAMESPACE already exists"
  exit 1
fi

# install redis
#helm install redis tyk-helm/simple-redis -n $NAMESPACE
helm show values bitnami/redis > $REDIS_YAML
yq '.auth.enabled = false' -i $REDIS_YAML
yq '.image.tag = "6.0.10"' -i $REDIS_YAML
yq '.architecture = "standalone"' -i $REDIS_YAML
helm install tyk-redis bitnami/redis -f $REDIS_YAML -n $NAMESPACE --wait

# install mongodb
#helm install mongo tyk-helm/simple-mongodb -n $NAMESPACE
helm show values bitnami/mongodb > $MONGO_YAML
yq '.auth.enabled = false' -i $MONGO_YAML
yq '.image.tag = "4.4"' -i $MONGO_YAML
yq '.architecture = "standalone"' -i $MONGO_YAML
yq '.livenessProbe.enabled = false' -i $MONGO_YAML
yq '.readinessProbe.enabled = false' -i $MONGO_YAML
# the bitnami chart adds -mongodb to the name so we'll just call it 'tyk' here and then connect using 'tyk-mongodb'
# it takes a while to start so we wait here
helm install tyk bitnami/mongodb -f $MONGO_YAML -n $NAMESPACE --wait

helm show values tyk-helm/tyk-pro > $TYK_YAML
# update $TYK_YAML
. ~/.tyk-sandbox
yq '.dash.image.tag = "v4.2.4"' -i $TYK_YAML
yq '.gateway.image.tag = "v4.2.4"' -i $TYK_YAML
yq '.pump.image.tag = "v1.6.0"' -i $TYK_YAML
yq '.dash.adminUser.email = "'$SBX_USER'"' -i $TYK_YAML
yq '.dash.adminUser.password = "'$(echo $SBX_PASSWORD| base64 -d)'"' -i $TYK_YAML
yq '.dash.license = "'$SBX_LICENSE'"' -i $TYK_YAML

# setup redis and mongo connections in tyk's yaml
yq '.redis.addrs = "tyk-redis-master.'$NAMESPACE'.svc.cluster.local:6379"' -i $TYK_YAML
yq '.mongo.mongoURL = "mongodb://tyk-mongodb.'$NAMESPACE'.svc.cluster.local:27017/tyk_analytics"' -i $TYK_YAML

## set env variables
# debug logging
yq '.pump.extraEnvs += { "name": "TYK_LOGLEVEL", "value": "debug" }' -i $TYK_YAML
yq '.gateway.extraEnvs += { "name": "TYK_LOGLEVEL", "value": "debug" }' -i $TYK_YAML
yq '.dash.extraEnvs += { "name": "TYK_LOGLEVEL", "value": "debug" }' -i $TYK_YAML

# enable key listing
yq '.dash.extraEnvs += { "name": "TYK_DB_ENABLEHASHEDKEYSLISTING", "value": "true" }' -i $TYK_YAML
yq '.gateway.extraEnvs += { "name": "TYK_GW_ENABLEHASHEDKEYSLISTING", "value": "true" }' -i $TYK_YAML
yq '.gateway.extraEnvs += { "name": "TYK_GW_HASHKEYFUNCTION", "value": "murmur64" }' -i $TYK_YAML

# change the gateway kind to deployment
yq '.gateway.kind = "Deployment"' -i $TYK_YAML

# things operator needs
yq '.gateway.extraEnvs += { "name": "TYK_GW_POLICIES_ALLOWEXPLICITPOLICYID", "value": "true" }' -i $TYK_YAML

helm install tyk-pro tyk-helm/tyk-pro -f $TYK_YAML -n $NAMESPACE --wait

# dashboard port is
echo Dashboard URL http://$(minikube ip):$(kubectl get --namespace $NAMESPACE -o jsonpath="{.spec.ports[0]}" services dashboard-svc-tyk-pro | jq .nodePort)

# gateway port is
echo Gateway URL http://$(minikube ip):$(kubectl get --namespace $NAMESPACE -o jsonpath="{.spec.ports[0]}" services gateway-svc-tyk-pro | jq .nodePort)

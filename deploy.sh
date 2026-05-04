#!/bin/bash
# Exit immediately if a command exits with a non-zero status.
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Error: Please provide your Google Cloud Project ID and APP NAME."
  echo "Usage: ./deploy_v3.sh <PROJECT_ID> <APP_NAME>"
  exit 1
fi

export PROJECT=$1
export APP=$2
export CLUSTER_NAME="edge-to-mesh"
export CLUSTER_LOCATION="us-central1"

echo "===================================================="
echo "Starting Deployment for Project: ${PROJECT}"
echo "===================================================="

# Set up environment variables
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT} --format="value(projectNumber)")
gcloud config set project ${PROJECT}

rm -rf ${HOME}/edge-to-mesh
# Create working directory
echo "--> Creating working directory..."
mkdir -p ${HOME}/edge-to-mesh
cd ${HOME}/edge-to-mesh
export WORKDIR=$(pwd)

# Set up isolated kubeconfig
touch edge2mesh_kubeconfig
export KUBECONFIG=${WORKDIR}/edge2mesh_kubeconfig

# Enable initial APIs
echo "--> Enabling required APIs..."
gcloud services enable container.googleapis.com mesh.googleapis.com certificatemanager.googleapis.com

# Create GKE Standard Cluster
echo "--> Checking GKE Standard cluster..."
if gcloud container clusters describe ${CLUSTER_NAME} --region ${CLUSTER_LOCATION} >/dev/null 2>&1; then
  echo "    Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
  gcloud container clusters get-credentials ${CLUSTER_NAME} --region ${CLUSTER_LOCATION}
else
  echo "    Creating GKE Standard cluster '${CLUSTER_NAME}' in ${CLUSTER_LOCATION} (3 nodes total)..."
  # Note: --num-nodes=1 in a regional cluster provisions 1 node per zone (3 zones = 3 nodes total)
  gcloud container clusters create ${CLUSTER_NAME} \
    --project ${PROJECT} \
    --region ${CLUSTER_LOCATION} \
    --release-channel stable \
    --machine-type e2-standard-4 \
    --num-nodes 1 \
    --workload-pool=${PROJECT}.svc.id.goog \
    --gateway-api=standard
fi

# Configure Cloud Service Mesh
echo "--> Configuring Cloud Service Mesh..."
gcloud container fleet mesh enable

if gcloud container fleet memberships describe ${CLUSTER_NAME} >/dev/null 2>&1; then
  echo "    Fleet membership '${CLUSTER_NAME}' already exists. Skipping registration."
else
  echo "    Registering cluster to fleet..."
  gcloud container fleet memberships register ${CLUSTER_NAME} --gke-cluster ${CLUSTER_LOCATION}/${CLUSTER_NAME}
fi

gcloud container clusters update ${CLUSTER_NAME} --project ${PROJECT} --region ${CLUSTER_LOCATION} --update-labels mesh_id=proj-${PROJECT_NUMBER}
gcloud container fleet mesh update --management automatic --memberships ${CLUSTER_NAME}

# =========================================================================
# SEQUENCE FIX 1: Wait for CSM to be fully ACTIVE before proceeding
# =========================================================================
echo "--> Waiting for Cloud Service Mesh Control Plane to become ACTIVE (can take 10+ minutes)..."
until gcloud container fleet mesh describe --project=${PROJECT} | grep -A 5 "controlPlaneManagement:" | grep -q "state: ACTIVE"; do
  echo "    ... still waiting for CSM Control Plane. Sleeping 30s..."
  sleep 30
done
echo "    CSM Control Plane is ACTIVE!"

echo "--> Waiting for Cloud Service Mesh Data Plane to become ACTIVE..."
until gcloud container fleet mesh describe --project=${PROJECT} | grep -A 5 "dataPlaneManagement:" | grep -q "state: ACTIVE"; do
  echo "    ... still waiting for CSM Data Plane. Sleeping 30s..."
  sleep 30
done
echo "    CSM Data Plane is ACTIVE!"
# =========================================================================

# Setup Ingress Gateway Namespace
echo "--> Checking Ingress Gateway namespace..."
if kubectl get namespace ingress-gateway >/dev/null 2>&1; then
  echo "    Namespace 'ingress-gateway' already exists. Skipping creation."
else
  echo "    Creating 'ingress-gateway' namespace..."
  kubectl create namespace ingress-gateway
fi
kubectl label namespace ingress-gateway istio-injection=enabled --overwrite

# Create Self-Signed Cert for Ingress Gateway
echo "--> Checking Ingress Gateway TLS secret..."
if kubectl -n ingress-gateway get secret edge2mesh-credential >/dev/null 2>&1; then
  echo "    Secret 'edge2mesh-credential' already exists. Skipping creation."
else
  echo "    Creating self-signed certificate and secret..."
  openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/CN=${APP}.endpoints.${PROJECT}.cloud.goog/O=Edge2Mesh Inc" \
    -keyout ${APP}.endpoints.${PROJECT}.cloud.goog.key \
    -out ${APP}.endpoints.${PROJECT}.cloud.goog.crt

  kubectl -n ingress-gateway create secret tls edge2mesh-credential \
    --key=${APP}.endpoints.${PROJECT}.cloud.goog.key \
    --cert=${APP}.endpoints.${PROJECT}.cloud.goog.crt
fi

# Create Ingress Gateway Manifests
echo "--> Generating Ingress Gateway manifests..."
mkdir -p ${WORKDIR}/ingress-gateway/base
cat <<EOF > ${WORKDIR}/ingress-gateway/base/kustomization.yaml
resources:
  - github.com/GoogleCloudPlatform/anthos-service-mesh-samples/docs/ingress-gateway-asm-manifests/base
EOF

mkdir -p ${WORKDIR}/ingress-gateway/variant
cat <<EOF > ${WORKDIR}/ingress-gateway/variant/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: asm-ingressgateway
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "watch", "list"]
EOF

cat <<EOF > ${WORKDIR}/ingress-gateway/variant/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: asm-ingressgateway
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: asm-ingressgateway
subjects:
  - kind: ServiceAccount
    name: asm-ingressgateway
EOF

cat <<EOF > ${WORKDIR}/ingress-gateway/variant/service-proto-type.yaml
apiVersion: v1
kind: Service
metadata:
  name: asm-ingressgateway
spec:
  ports:
  - name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
  - name: http
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 8443
    appProtocol: HTTP2
  type: ClusterIP
EOF

cat <<EOF > ${WORKDIR}/ingress-gateway/variant/gateway.yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: asm-ingressgateway
spec:
  selector:
    asm: ingressgateway # <--- CRITICAL FIX: Links config to the pod
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - "*"
    tls:
      mode: SIMPLE
      credentialName: edge2mesh-credential
EOF

cat <<EOF > ${WORKDIR}/ingress-gateway/variant/kustomization.yaml
namespace: ingress-gateway
resources:
- ../base
- role.yaml
- rolebinding.yaml
- gateway.yaml # <--- CRITICAL FIX: Moved from patches to resources
patches:
- path: service-proto-type.yaml
  target:
    kind: Service
EOF

# Wait for managed Istio CRDs to be provisioned by the Fleet
echo "--> Waiting for Cloud Service Mesh CRDs to be injected into the cluster..."
until kubectl get crd gateways.networking.istio.io >/dev/null 2>&1; do
  echo "    Still waiting for gateways.networking.istio.io CRD..."
  sleep 15
done

echo "--> Istio CRDs found. Waiting for them to become fully established..."
kubectl wait --for condition=established --timeout=120s crd/gateways.networking.istio.io
kubectl wait --for condition=established --timeout=120s crd/virtualservices.networking.istio.io

# =========================================================================
# SEQUENCE FIX 2: Wait for Webhooks & Robust Pod Check
# =========================================================================
echo "--> Waiting for Cloud Service Mesh Sidecar Injector Webhook to come online..."
until kubectl get mutatingwebhookconfigurations | grep -i "istio" >/dev/null 2>&1; do
  echo "    Still waiting for Istio webhook configuration..."
  sleep 10
done
echo "    Istio webhook configuration found!"

echo "--> Applying Ingress Gateway Manifests..."
kubectl apply -k ${WORKDIR}/ingress-gateway/variant

echo "--> Forcing a rollout restart to ensure Envoy sidecars are injected properly..."
sleep 15
kubectl rollout restart deployment asm-ingressgateway -n ingress-gateway || true

echo "--> Waiting for GKE to provision nodes and schedule pods..."

TIMEOUT=900
INTERVAL=30
ELAPSED=0

until kubectl wait --for=condition=available --timeout=${INTERVAL}s deployment/asm-ingressgateway -n ingress-gateway >/dev/null 2>&1; do
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "    ... still waiting for asm-ingressgateway deployment to be available (${ELAPSED}s elapsed) ..."
  
  echo "    [Current Pod Status]:"
  kubectl get pods -n ingress-gateway -l asm=ingressgateway
  
  # Check for ReplicaSet webhook failures if no pods exist
  if ! kubectl get pods -n ingress-gateway -l asm=ingressgateway | grep -q "asm-ingressgateway"; then
     echo "    [ReplicaSet Warning]: No pods exist! Checking ReplicaSet events for Webhook failures..."
     kubectl describe replicaset -n ingress-gateway | grep -A 10 "Events:" || true
  fi
  
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Error: Timed out waiting for asm-ingressgateway to become available."
    exit 1
  fi
done
echo "--> Ingress Gateway is successfully available!"
# =========================================================================

# HealthCheck Policy
echo "--> Applying HealthCheckPolicy..."
cat <<EOF >${WORKDIR}/ingress-gateway-healthcheck.yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: ingress-gateway-healthcheck
  namespace: ingress-gateway
spec:
  default:
    checkIntervalSec: 20
    timeoutSec: 5
    logConfig:
      enabled: True
    config:
      type: HTTP
      httpHealthCheck:
        port: 15021
        portName: status-port
        requestPath: /healthz/ready
  targetRef:
    group: ""
    kind: Service
    name: asm-ingressgateway
EOF
kubectl apply -f ${WORKDIR}/ingress-gateway-healthcheck.yaml

# Cloud Armor Policy
echo "--> Checking Cloud Armor security policies..."
if gcloud compute security-policies describe edge-fw-policy >/dev/null 2>&1; then
  echo "    Security policy 'edge-fw-policy' already exists. Skipping creation."
else
  echo "    Creating security policy 'edge-fw-policy'..."
  gcloud compute security-policies create edge-fw-policy --description "Block XSS attacks"
fi

if gcloud compute security-policies rules describe 1000 --security-policy edge-fw-policy >/dev/null 2>&1; then
  echo "    Security policy rule '1000' already exists. Skipping creation."
else
  echo "    Creating security policy rule '1000'..."
  gcloud compute security-policies rules create 1000 \
      --security-policy edge-fw-policy \
      --expression "evaluatePreconfiguredExpr('xss-stable')" \
      --action "deny-403" \
      --description "XSS attack filtering"
fi

cat <<EOF > ${WORKDIR}/cloud-armor-backendpolicy.yaml
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: cloud-armor-backendpolicy
  namespace: ingress-gateway
spec:
  default:
    securityPolicy: edge-fw-policy
  targetRef:
    group: ""
    kind: Service
    name: asm-ingressgateway
EOF
kubectl apply -f ${WORKDIR}/cloud-armor-backendpolicy.yaml

# Static IP & Cloud Endpoints DNS
echo "--> Checking global static IP address..."
if gcloud compute addresses describe e2m-gclb-ip --global >/dev/null 2>&1; then
  echo "    Static IP 'e2m-gclb-ip' already exists. Skipping creation."
else
  echo "    Reserving global static IP address 'e2m-gclb-ip'..."
  gcloud compute addresses create e2m-gclb-ip --global
fi
export GCLB_IP=$(gcloud compute addresses describe e2m-gclb-ip --global --format "value(address)")

echo "--> Deploying Cloud Endpoints DNS mapping to ${GCLB_IP}..."
cat <<EOF > ${WORKDIR}/dns-spec.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "${APP}.endpoints.${PROJECT}.cloud.goog"
x-google-endpoints:
- name: "${APP}.endpoints.${PROJECT}.cloud.goog"
  target: "${GCLB_IP}"
EOF
gcloud endpoints services deploy ${WORKDIR}/dns-spec.yaml

# TLS Certificate via Certificate Manager
echo "--> Checking Certificate Manager resources..."
if gcloud certificate-manager certificates describe edge2mesh-cert >/dev/null 2>&1; then
  echo "    Certificate 'edge2mesh-cert' already exists. Skipping creation."
else
  echo "    Provisioning TLS certificate 'edge2mesh-cert'..."
  gcloud certificate-manager certificates create edge2mesh-cert --domains="${APP}.endpoints.${PROJECT}.cloud.goog"
fi

if gcloud certificate-manager maps describe edge2mesh-cert-map >/dev/null 2>&1; then
  echo "    Certificate map 'edge2mesh-cert-map' already exists. Skipping creation."
else
  echo "    Creating certificate map 'edge2mesh-cert-map'..."
  gcloud certificate-manager maps create edge2mesh-cert-map
fi

if gcloud certificate-manager maps entries describe edge2mesh-cert-map-entry --map="edge2mesh-cert-map" >/dev/null 2>&1; then
  echo "    Certificate map entry 'edge2mesh-cert-map-entry' already exists. Skipping creation."
else
  echo "    Creating certificate map entry..."
  gcloud certificate-manager maps entries create edge2mesh-cert-map-entry \
      --map="edge2mesh-cert-map" \
      --certificates="edge2mesh-cert" \
      --hostname="${APP}.endpoints.${PROJECT}.cloud.goog"
fi

# Deploy GKE Gateway & Routes
echo "--> Deploying GKE Gateway and HTTPRoutes..."
cat <<EOF > ${WORKDIR}/gke-gateway.yaml
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: external-http
  namespace: ingress-gateway
  annotations:
    networking.gke.io/certmap: edge2mesh-cert-map
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
  - name: http
    protocol: HTTP
    port: 80
  - name: https
    protocol: HTTPS
    port: 443
  addresses:
  - type: NamedAddress
    value: e2m-gclb-ip
EOF
kubectl apply -f ${WORKDIR}/gke-gateway.yaml

cat << EOF > ${WORKDIR}/default-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: default-httproute
  namespace: ingress-gateway
spec:
  parentRefs:
  - name: external-http
    namespace: ingress-gateway
    sectionName: https
  rules:
  - matches:
    - path:
        value: /
    backendRefs:
    - name: asm-ingressgateway
      port: 443
EOF
kubectl apply -f ${WORKDIR}/default-httproute.yaml

cat << EOF > ${WORKDIR}/default-httproute-redirect.yaml
kind: HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: http-to-https-redirect-httproute
  namespace: ingress-gateway
spec:
  parentRefs:
  - name: external-http
    namespace: ingress-gateway
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
EOF
kubectl apply -f ${WORKDIR}/default-httproute-redirect.yaml

# Deploy Sample App (Online Boutique)
echo "--> Checking Online Boutique namespace..."
if kubectl get namespace onlineboutique >/dev/null 2>&1; then
  echo "    Namespace 'onlineboutique' already exists. Skipping creation."
else
  echo "    Creating 'onlineboutique' namespace..."
  kubectl create namespace onlineboutique
fi
kubectl label namespace onlineboutique istio-injection=enabled --overwrite

echo "--> Deploying Online Boutique sample app..."

gcloud container clusters get-credentials $CLUSTER_NAME --region $CLUSTER_LOCATION --project $PROJECT

curl -LO \
https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml

kubectl apply -f ${WORKDIR}/kubernetes-manifests.yaml -n onlineboutique

echo "--> Generating VirtualService routing..."

cat << EOF > ${WORKDIR}/virtualservice.yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: frontend-ingress
  namespace: onlineboutique
spec:
  hosts:
  - "${APP}.endpoints.${PROJECT}.cloud.goog"
  gateways:
  - ingress-gateway/asm-ingressgateway
  http:
  - route:
    - destination:
        host: frontend
        port:
          number: 80
EOF

kubectl apply -f ${WORKDIR}/virtualservice.yaml

echo "===================================================="
echo "Deployment completed!"
echo "App URL: https://${APP}.endpoints.${PROJECT}.cloud.goog"
echo "Note: It may take up to 15 minutes for the Cloud Load Balancer and SSL Certificates to fully provision."
echo "===================================================="

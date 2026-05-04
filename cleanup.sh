#!/bin/bash
# Cleanup script to safely remove edge-to-mesh resources.
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Error: Please provide your Google Cloud Project ID and APP NAME."
  echo "Usage: ./cleanup.sh <PROJECT_ID> <APP_NAME>"
  exit 1
fi

export PROJECT=$1
export APP=$2
export CLUSTER_NAME="edge-to-mesh"
export CLUSTER_LOCATION="us-central1"
export WORKDIR="${HOME}/edge-to-mesh"
export KUBECONFIG=${WORKDIR}/edge2mesh_kubeconfig

echo "===================================================="
echo "Starting Cleanup for Project: ${PROJECT} | App: ${APP}"
echo "===================================================="

# Ensure gcloud is pointing to the correct project
gcloud config set project ${PROJECT} --quiet

# =========================================================================
# 1. LOAD BALANCER CLEANUP (Via Gateway Controller)
# We must do this via kubectl before the cluster is destroyed, otherwise 
# the external GCP Load Balancer components will be orphaned.
# =========================================================================
echo "--> Looking up GKE Gateway to safely tear down the GCP Load Balancer..."
if kubectl get gateway external-http -n ingress-gateway >/dev/null 2>&1; then
  echo "    Found. Deleting Gateway (This triggers GCP Load Balancer teardown)..."
  kubectl delete gateway external-http -n ingress-gateway
  
  echo "    Waiting for GKE Gateway controller to cleanly remove the Load Balancer..."
  echo "    (This can take 3-5 minutes. Do not interrupt.)"
  while kubectl get gateway external-http -n ingress-gateway >/dev/null 2>&1; do
    echo "    ... still tearing down load balancer infrastructure in GCP ..."
    sleep 15
  done
  echo "    GCP Load Balancer successfully removed."
else
  echo "    Gateway 'external-http' not found. Moving on."
fi
# =========================================================================

# 2. CERTIFICATE MANAGER CLEANUP
echo "--> Looking up Certificate Map Entry 'edge2mesh-cert-map-entry'..."
if gcloud certificate-manager maps entries describe edge2mesh-cert-map-entry --map="edge2mesh-cert-map" >/dev/null 2>&1; then
  echo "    Found. Deleting certificate map entry..."
  gcloud certificate-manager maps entries delete edge2mesh-cert-map-entry --map="edge2mesh-cert-map" --quiet
else
  echo "    Certificate map entry not found. Moving on."
fi

echo "--> Looking up Certificate Map 'edge2mesh-cert-map'..."
if gcloud certificate-manager maps describe edge2mesh-cert-map >/dev/null 2>&1; then
  echo "    Found. Deleting certificate map..."
  gcloud certificate-manager maps delete edge2mesh-cert-map --quiet
else
  echo "    Certificate map not found. Moving on."
fi

echo "--> Looking up TLS Certificate 'edge2mesh-cert'..."
if gcloud certificate-manager certificates describe edge2mesh-cert >/dev/null 2>&1; then
  echo "    Found. Deleting TLS certificate..."
  gcloud certificate-manager certificates delete edge2mesh-cert --quiet
else
  echo "    TLS certificate not found. Moving on."
fi

# 3. CLOUD ENDPOINTS (DNS) CLEANUP
echo "--> Looking up Cloud Endpoints Service '${APP}.endpoints.${PROJECT}.cloud.goog'..."
if gcloud endpoints services describe ${APP}.endpoints.${PROJECT}.cloud.goog >/dev/null 2>&1; then
  echo "    Found. Deleting Cloud Endpoints DNS..."
  gcloud endpoints services delete ${APP}.endpoints.${PROJECT}.cloud.goog --quiet
else
  echo "    Cloud Endpoints Service not found. Moving on."
fi

# 4. GLOBAL STATIC IP CLEANUP
echo "--> Looking up Global Static IP 'e2m-gclb-ip'..."
if gcloud compute addresses describe e2m-gclb-ip --global >/dev/null 2>&1; then
  echo "    Found. Deleting Global Static IP..."
  gcloud compute addresses delete e2m-gclb-ip --global --quiet
else
  echo "    Global Static IP not found. Moving on."
fi

# 5. CLOUD ARMOR SECURITY POLICIES CLEANUP
echo "--> Looking up Cloud Armor security policy rule '1000'..."
if gcloud compute security-policies rules describe 1000 --security-policy edge-fw-policy >/dev/null 2>&1; then
  echo "    Found. Deleting security policy rule '1000'..."
  gcloud compute security-policies rules delete 1000 --security-policy edge-fw-policy --quiet
else
  echo "    Security policy rule '1000' not found. Moving on."
fi

echo "--> Looking up Cloud Armor security policy 'edge-fw-policy'..."
if gcloud compute security-policies describe edge-fw-policy >/dev/null 2>&1; then
  echo "    Found. Deleting security policy 'edge-fw-policy'..."
  gcloud compute security-policies delete edge-fw-policy --quiet
else
  echo "    Security policy not found. Moving on."
fi

# 6. CLOUD SERVICE MESH FLEET CLEANUP
echo "--> Looking up Fleet membership for '${CLUSTER_NAME}'..."
if gcloud container fleet memberships describe ${CLUSTER_NAME} >/dev/null 2>&1; then
  echo "    Found. Unregistering cluster from fleet..."
  gcloud container fleet memberships unregister ${CLUSTER_NAME} --gke-cluster ${CLUSTER_LOCATION}/${CLUSTER_NAME} --project ${PROJECT} --quiet
else
  echo "    Fleet membership not found. Moving on."
fi

# 7. GKE CLUSTER CLEANUP
echo "--> Looking up GKE Standard cluster '${CLUSTER_NAME}'..."
if gcloud container clusters describe ${CLUSTER_NAME} --region ${CLUSTER_LOCATION} >/dev/null 2>&1; then
  echo "    Found. Deleting GKE cluster '${CLUSTER_NAME}' (This will wipe all internal namespaces and apps. This takes several minutes)..."
  gcloud container clusters delete ${CLUSTER_NAME} --region ${CLUSTER_LOCATION} --project ${PROJECT} --quiet
else
  echo "    GKE cluster not found. Moving on."
fi

# 8. LOCAL WORKDIR CLEANUP
echo "--> Checking for local working directory..."
if [ -d "${WORKDIR}" ]; then
  echo "    Found. Removing local working directory..."
  rm -rf ${WORKDIR}
else
  echo "    Local working directory not found. Moving on."
fi

echo "===================================================="
echo "Cleanup completed successfully! All processes finished."
echo "===================================================="

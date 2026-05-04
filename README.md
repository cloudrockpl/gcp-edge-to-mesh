# GCP Edge-to-Mesh Architecture 

A secure, end-to-end routing architecture built and deployed entirely on Google Cloud Platform (GCP).

This project demonstrates a modern networking stack connecting global external traffic through Cloud Load Balancing into a GKE Standard cluster, managed by Cloud Service Mesh (CSM), and utilizing the modern GKE Gateway API. It includes automated infrastructure provisioning via shell scripts.

---

## Architecture

<img width="2816" height="1536" alt="edge-to-mesh architecture" src="https://github.com/user-attachments/assets/ab34b67f-e300-410d-8bb7-b826a44dfe62" />



---

## Core Components

### Global Edge Services
A Global External Application Load Balancer attached to a static IP, utilizing Cloud Armor WAF for security filtering and Certificate Manager for public TLS termination.

### GKE Gateway API
Kubernetes-native routing resources (`Gateway`, `HTTPRoute`) that dynamically provision and configure the external Cloud Load Balancer directly from the cluster.

### Cloud Service Mesh (CSM)
Google's managed Traffic Director control plane and Envoy sidecar proxies, providing Istio-based internal routing and strict mTLS node-to-node encryption.

### GKE Standard Cluster
The compute layer hosting the Istio Ingress Gateway and the sample microservices application (Online Boutique) with Workload Identity enabled.

---

## Quick Start

### Prerequisites

* ** A Google Cloud Platform (GCP) account.
* ** Google Cloud CLI (gcloud) installed and authenticated.
* ** Billing enabled on your GCP project.
* ** `kubectl` and `openssl` installed locally.

### Deployment

#### 1) Clone this repository

```bash
git clone https://github.com/cloudrockpl/gcp-edge-to-mesh.git
cd gcp-edge-to-mesh
```

#### 2) Set your active GCP project

```bash
gcloud config set project YOUR_PROJECT_ID
```

#### 3) Make the deployment script executable and run it

```bash
chmod +x deploy.sh
./deploy.sh YOUR_PROJECT_ID YOUR_APP_NAME
```

## Once completed, the script will output the live public URL for your application. Wait an additional 10-15 minutes for the global SSL certificates to propagate, then click it to view the app!

## Clean Up

To avoid incurring unwanted charges, tear down the entire architecture when you are finished testing:

```bash
chmod +x cleanup.sh
./cleanup.sh YOUR_PROJECT_ID YOUR_APP_NAME
```

> **Note:** This cleanup script safely deletes the Cloud Endpoints DNS records, Certificate Manager resources, the GKE Cluster (which removes the Load Balancer), Fleet Mesh registrations, Cloud Armor policies, and Global Static IPs created by the deployment script.

---

## Repository Structure

```text
.
├── deploy.sh     # Master deployment script (IaC)
├── cleanup.sh       # Master teardown script
└── README.md        # Project documentation
```

---

## Tech Stack

### Infrastructure & Compute
* GKE Standard
* Google Cloud Fleet
* Cloud Service Mesh (Traffic Director)

### Edge Networking & Security
* Global External Application Load Balancer
* Cloud Armor
* Certificate Manager
* Cloud Endpoints (DNS)
* GKE Gateway API

### Application Routing
* Istio (VirtualService, Gateway)
* Envoy Proxies (Sidecars)
* Kubernetes Service / Deployment

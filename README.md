# Global Load Balancer with Backend mTLS using Managed Workload Identity (MWLID)

## Overview

This repository contains a Terraform configuration that deploys a secured **Global External Application Load Balancer (GXLB)** configuration where the connection between the Load Balancer and the Backend Instances is authenticated via **Mutual TLS (mTLS)**.

Instead of manually managing SSL certificates and private keys on the backend VMs, this solution leverages **Google Cloud Managed Workload Identity (MWLID)**. Both the Load Balancer and the Compute Engine instances automatically acquire short-lived, rotatable X.509 SVIDs (SPIFFE Verifiable Identity Documents) from Google Private CA to establish a trusted, encrypted channel.

## Core Concepts

### 1. Identity Authority

A **Private CA (Certificate Authority Service)** is configured as the root of trust. A **Workload Identity Pool** is set up in `TRUST_DOMAIN` mode to act as the bridge between the infrastructure resources and the Private CA.

### 2. Managed Workload Identity (MWLID)

MWLID enables workloads to autonomously retrieve X.509 certificates based on their platform attributes (Attestation) without handling sensitive private key material during provisioning.

## Implementation Details

### The Backend: Managed Instance Group (MIG)

The backend instances are configured to automatically request certificates upon startup.

* **Attestation:** The Workload Identity Pool is configured with an attestation rule that trusts the specific Service Account attached to the Instance Group:
```hcl
# Terraform Resource: google_iam_workload_identity_pool_managed_identity
attestation_rules {
  google_cloud_resource = "//compute.googleapis.com/.../attached_service_account.email/${google_service_account.ig_1_sa.email}" 
}

```


* **Configuration (Partner Metadata):**
The instances receive their MWLID configuration via `partner_metadata`. This tells the Metadata Server:
1. **`wc.compute.googleapis.com`**: Where to fetch certificates (The CA Pool) and which CA Pool to trust (Trust Anchor).
2. **`iam.googleapis.com`**: The specific SPIFFE ID the instance should assume.


```json
// Example Metadata Structure
{
  "trust-config": { ... },
  "workload-identity": "spiffe://<POOL_ID>/ns/<NAMESPACE>/sa/<MANAGED_ID>"
}

```


* **Certificate Handling:** A startup script (`startup_mwlid.sh`) is used to interact with the local metadata server to fetch the certificate and place it where the Apache2 server can use it.

### The Frontend: Global Load Balancer (Backend Service)

The Global Load Balancer acts as a client when connecting to the backend. It also utilizes MWLID to present a client certificate to the backend instances.

* **Attestation:** The Workload Identity Pool allows the Load Balancer resources to request certificates via a specific resource type attestation:
```hcl
attestation_rules {
  google_cloud_resource = "//compute.googleapis.com/projects/${project_number}/type/BackendService/*"
}

```


* **Configuration (GCloud Beta):**
*Note: Native MWLID on Backend Services is currently in Preview and Terraform support will follow by GA date*
The configuration uses a `null_resource` with `local-exec` to provision the Backend Service using `gcloud beta`. Crucially, it sets the `--identity` flag:
```bash
gcloud beta compute backend-services create ... \
  --protocol=HTTPS \
  --identity='//<POOL_ID>.global.<PROJECT_NUMBER>.workload.id.goog/ns/<NAMESPACE>/sa/<MANAGED_ID>'

```


This flag instructs the Global Load Balancer to perform the mTLS handshake using a certificate derived from that specific SPIFFE identity.

## Authentication Flow

1. **Boot:** The Backend VM starts. The OS Metadata agent sees the `partner_metadata` and requests a certificate from Private CA via the Workload Identity Pool.
2. **Request:** The Global Load Balancer receives a request. It routes traffic to the Backend Service.
3. **Handshake:** * The LB connects to the Backend VM.
* The LB presents its SPIFFE certificate (acquired via the `--identity` config).
* The Backend VM validates the LB's certificate against the CA Pool (Trust Anchor).
* The Backend VM presents its own SPIFFE certificate.
* The LB validates the Backend VM's certificate.


4. **Traffic:** Once mutual trust is established, encrypted traffic flows.

## Deployment Prerequisites

* **Terraform:** v1.0+
* **Google Cloud SDK:** Version 546.0.0 or higher (Required for `gcloud beta` commands).
* **Permissions:** Project Owner or Editor permissions to create Private CA pools, Network Security resources, and Compute instances.

## How to Deploy

1. **Initialize Terraform:**
```bash
terraform init

```


2. **Review Plan:**
```bash
terraform plan -var="sg_project_id=YOUR_PROJECT_ID"

```


3. **Apply:**
```bash
terraform apply -var="sg_project_id=YOUR_PROJECT_ID"

```



## Verification

To verify the setup, you can access the **Siege Host** (deployed in the VPC) which also utilizes MWLID to authenticate against the load balancer or backends directly for testing.

1. From GCP console execute CURL: curl -k -vv https://<LB_IP_ADDRESS>/server.php
2. Observe headers received from LB
3. Inspect the Private CA logs to see certificate issuance events for both the "Backend Service" principal and the "VM" principal.


# Known caveats:
- You may need to rerun "terraform apply" due to bug/inconsistency after first run



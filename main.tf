locals {
  zone-a = "${var.region_a}-b"
  zone-b = "${var.region_b}-c" 
}

provider "google" {
}

resource "random_id" "id" {
  byte_length = 4
  prefix      = var.sg_prefix
}


############ PROJECT ###############

# resource "google_project" "producer" {
#   org_id              = var.parent.parent_type == "organizations" ? var.parent.parent_id : null
#   folder_id           = var.parent.parent_type == "folders" ? var.parent.parent_id : null
#   name                = "${var.producer_project_name}-${random_id.id.hex}"
#   project_id          = "${var.producer_project_name}-${random_id.id.hex}"
#   billing_account     = var.billing_account
#   auto_create_network = false
# }

data "google_project" "producer" {
    project_id = var.sg_project_id
}


resource "google_project_service" "producer_service" {
  for_each = toset([
    "compute.googleapis.com",
    "privateca.googleapis.com",
    "networksecurity.googleapis.com",
    "certificatemanager.googleapis.com"
  ])

  service            = each.key
  project            = data.google_project.producer.project_id
  disable_on_destroy = false
}


########### PRIVATE CA POOLS ###############

resource "google_privateca_ca_pool" "producer_ca_pool" {
  name     = "${random_id.id.hex}-ca-pool"
  project  = data.google_project.producer.project_id
  location = var.region_a
  tier     = "ENTERPRISE"

  depends_on = [
    google_project_service.producer_service
  ]
}

resource "google_privateca_certificate_authority" "root_root_ca" {
  pool     = google_privateca_ca_pool.producer_ca_pool.name
  project  = data.google_project.producer.project_id
  location = var.region_a
  
  certificate_authority_id = "${random_id.id.hex}-root-ca"
 
  ignore_active_certificates_on_deletion = true
  deletion_protection = false
  skip_grace_period   = true
  
  type = "SELF_SIGNED"
  lifetime = "31536000s" # 1 year

  key_spec {
    algorithm = "EC_P256_SHA256"
  }

  config {
    subject_config {
      subject {
        organization = "SG Producer Root CA"
        common_name  = "SG Producer Root CA"
      }
    }
    x509_config {
      ca_options {
        is_ca = true
      }
      key_usage {
        base_key_usage {
          cert_sign          = true
          crl_sign           = true
        }
        extended_key_usage {
          server_auth        = true
          client_auth        = true
        }
      }
    }
  }
  depends_on = [
    google_privateca_ca_pool.producer_ca_pool
  ]

}


resource "google_iam_workload_identity_pool" "sg" {
  provider = google-beta
  
  project                   = data.google_project.producer.project_id
  workload_identity_pool_id = "${random_id.id.hex}-pool"
  display_name              = "${random_id.id.hex}-pool"
  description               = "SG Workload Identity Pool"
  mode                      = "TRUST_DOMAIN"
  inline_certificate_issuance_config {
    ca_pools = {      
      "${var.region_a}" : "${google_privateca_ca_pool.producer_ca_pool.id}"
    }
    lifetime                   = "86400s"
    rotation_window_percentage = 50
    key_algorithm              = "ECDSA_P256"
  }

  # inline_trust_config {
  #   additional_trust_bundles {
  #     trust_domain    = "example.com"
  #     pem_certificate = "-----BEGIN CERTIFICATE-----MIIBsjCCAVigAwIBAgIUANBgZ8NfNIWaOlm66VhaQ7QRRjowCgYIKoIzj0EAwIwJTEPMA0GA1UEChMGc2cuY29tMRIwEAYDVQQDEwlzZWJhc3RpYW4wHhcNMjUxMTA1MTMzODMzWhcNMzUxMTA1MjM0NjEzWjAlMQ8wDQYDVQQKEwZzZy5jb20xEjAQBgNVBAMTCXNlYmFzdGlhbjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABI+EP0agfucrKkOxKzE2GJOMqKzgDuIe/E6tQpJIUv7hGz1AkPm9FfPnzWfat8rBVOY4+OiySuNrr50u3TYPsR+jZjBkMA4GA1UdDwEB/wQEAwIBBjASBgNVHRMBAf8ECDAGAQH/AgEBMB0GA1UdDgQWBBTW2lGfXyB1gIMkIkR+LMig7VZqZzAfBgNVHSMEGDAWgBTW2lGfXyB1gIMkIkR+LMig7VZqZzAKBggqhkjOPQQDAgNIADBFAiA/tHClHPmC4CWFoUE+4euXvx2/PoTgJTENgQzlLkV9OgIhAJ+gTUBF+WwrtvwWu1DzXWseBMwOi5wU9PbVOEK124Tf-----END CERTIFICATE-----"
  #     }
  #   }
}


resource "google_iam_workload_identity_pool_namespace" "sg" {
  provider = google-beta

  workload_identity_pool_id           = google_iam_workload_identity_pool.sg.workload_identity_pool_id
  workload_identity_pool_namespace_id = "${random_id.id.hex}-ns"
}


resource "google_iam_workload_identity_pool_managed_identity" "sg" {
  provider = google-beta

  workload_identity_pool_id                  = google_iam_workload_identity_pool.sg.workload_identity_pool_id
  workload_identity_pool_namespace_id        = google_iam_workload_identity_pool_namespace.sg.workload_identity_pool_namespace_id
  workload_identity_pool_managed_identity_id = "${random_id.id.hex}-managed-identity"
   attestation_rules {
    google_cloud_resource = "//compute.googleapis.com/projects/${data.google_project.producer.number}/type/BackendService/*"
  }
# Attestation for SIEGE host to receive SPIFFE  
   attestation_rules {
    google_cloud_resource = "//compute.googleapis.com/projects/${data.google_project.producer.number}/type/Instance/attached_service_account.email/${google_service_account.siege_sa.email}" 
 } 

}

resource "google_privateca_ca_pool_iam_member" "sg_cert_requester" {
  ca_pool  = google_privateca_ca_pool.producer_ca_pool.id
  location = var.region_a
  project  = data.google_project.producer.project_id
  role     = "roles/privateca.workloadCertificateRequester"
  member   = "principalSet://iam.googleapis.com/projects/${data.google_project.producer.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.sg.workload_identity_pool_id}/*"

}

resource "google_privateca_ca_pool_iam_member" "sg_cert_reader" {
  ca_pool  = google_privateca_ca_pool.producer_ca_pool.id
  location = var.region_a
  project  = data.google_project.producer.project_id
  role     = "roles/privateca.poolReader"
  member   = "principalSet://iam.googleapis.com/projects/${data.google_project.producer.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.sg.workload_identity_pool_id}/*"

}

#
# Backend service is configred with "gcloud beta" as in preview there is no Terraform support.
# This command requires Google Cloud SDK 546.0.0 or higher
#
resource "null_resource" "backend_service_manager" {
  triggers = {
    backend_service_name = "${random_id.id.hex}-bs"
    project_id           = data.google_project.producer.project_id
    project_number       = data.google_project.producer.number
  }

  # Provisioner to create the backend service
  provisioner "local-exec" {
    when    = create
    command = <<EOT
gcloud beta compute backend-services create ${self.triggers.backend_service_name} \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTPS \
  --port-name="my-port" \
  --health-checks=${google_compute_health_check.tcp_health_check.name} \
  --identity='//${google_iam_workload_identity_pool.sg.workload_identity_pool_id}.global.${data.google_project.producer.number}.workload.id.goog/ns/${google_iam_workload_identity_pool_managed_identity.sg.workload_identity_pool_namespace_id}/sa/${google_iam_workload_identity_pool_managed_identity.sg.workload_identity_pool_managed_identity_id}' \
  --global \
  --project=${self.triggers.project_id}
EOT
  }

  # Provisioner to delete the backend service
  provisioner "local-exec" {
    when    = destroy
    # Reference values only from self.triggers
    command = <<EOT
gcloud beta compute backend-services delete ${self.triggers.backend_service_name} \
  --global \
  --project=${self.triggers.project_id} \
  --quiet
EOT
  }
}

# ####### VPC NETWORK

resource "google_compute_network" "producer_vpc_network" {
  name                    = "${random_id.id.hex}-vpc"
  auto_create_subnetworks = false
  mtu                     = 1460
  project                 = data.google_project.producer.project_id
}


####### VPC SUBNETS

resource "google_compute_subnetwork" "producer_sb_subnet_a" {
  name          = "${random_id.id.hex}-subnet-a"
  project       = data.google_project.producer.project_id
  ip_cidr_range = "10.10.20.0/24"
  network       = google_compute_network.producer_vpc_network.id
  region        = var.region_a
}

resource "google_compute_subnetwork" "producer_sb_subnet_b" {
  name          = "${random_id.id.hex}-subnet-b"
  project       = data.google_project.producer.project_id
  ip_cidr_range = "10.10.40.0/24"
  network       = google_compute_network.producer_vpc_network.id
  region        = var.region_b
}

resource "google_compute_subnetwork" "producer_proxy" {
  name          = "${random_id.id.hex}-l7-proxy-subnet"
  project       = data.google_project.producer.project_id
  region        = var.region_a
  ip_cidr_range = "10.10.200.0/24"
  network       = google_compute_network.producer_vpc_network.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"


}

####### FIREWALL

resource "google_compute_firewall" "producer_fw-allow-internal" {
  name      = "${random_id.id.hex}-allow-internal"
  project   = data.google_project.producer.project_id
  network   = google_compute_network.producer_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [
    google_compute_subnetwork.producer_sb_subnet_a.ip_cidr_range,
    google_compute_subnetwork.producer_sb_subnet_b.ip_cidr_range]
}

resource "google_compute_firewall" "producer_fw_allow_ssh" {
  name      = "${random_id.id.hex}-allow-ssh"
  project   = data.google_project.producer.project_id
  network   = google_compute_network.producer_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "producer_fw_app_allow_http" {
  name      = "${random_id.id.hex}-app-allow-http"
  project   = data.google_project.producer.project_id
  network   = google_compute_network.producer_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "8080", "443"]
  }
  target_tags   = ["lb-backend"]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "producer_fw_app_allow_health_check" {
  name      = "${random_id.id.hex}-app-allow-health-check"
  project   = data.google_project.producer.project_id
  network   = google_compute_network.producer_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }
  target_tags   = ["lb-backend"]
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

#### NAT

resource "google_compute_router" "producer_router_region_a" {
  name    = "${random_id.id.hex}-nat-rtr-region-a"
  project = data.google_project.producer.project_id
  network = google_compute_network.producer_vpc_network.id
  region  = var.region_a

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "producer_nat_region_a" {
  name                               = "${random_id.id.hex}-rtr-nat-region-a"
  project                            = data.google_project.producer.project_id
  router                             = google_compute_router.producer_router_region_a.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  region                             = var.region_a

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_router" "producer_router_region_b" {
  name    = "${random_id.id.hex}-nat-rtr-region-b"
  project = data.google_project.producer.project_id
  network = google_compute_network.producer_vpc_network.id
  region  = var.region_b

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "producer_nat_region_b" {
  name                               = "${random_id.id.hex}-rtr-nat-region-b"
  project                            = data.google_project.producer.project_id
  router                             = google_compute_router.producer_router_region_b.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  region                             = var.region_b

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}



# ###################### HTTPS Global LB #####################

# # Self-signed regional SSL certificate for testing
# resource "tls_private_key" "producer" {
#   algorithm = "RSA"
#   rsa_bits  = 2048
# }

# resource "tls_self_signed_cert" "producer" {
#   private_key_pem = tls_private_key.producer.private_key_pem

#   # Certificate expires after 48 hours.
#   validity_period_hours = 48

#   # Generate a new certificate if Terraform is run within three
#   # hours of the certificate's expiration time.
#   early_renewal_hours = 3

#   # Reasonable set of uses for a server SSL certificate.
#   allowed_uses = [
#     "key_encipherment",
#     "digital_signature",
#     "server_auth",
#   ]

#   dns_names = ["sg-test-producer.com"]

#   subject {
#     common_name  = "sg-test-producer.com"
#     organization = "SG Test Producer"
#   }
# }

# resource "google_compute_ssl_certificate" "producer" {
#   project     = data.google_project.producer.project_id
#   name_prefix = "${random_id.id.hex}-cert-"
#   private_key = tls_private_key.producer.private_key_pem
#   certificate = tls_self_signed_cert.producer.cert_pem
#   lifecycle {
#     create_before_destroy = true
#   }
# }

resource "google_compute_health_check" "tcp_health_check" {
  name               = "${random_id.id.hex}-tcp-hc"
  project            = data.google_project.producer.project_id
  timeout_sec        = 1
  check_interval_sec = 1


  tcp_health_check {
    port = "80"
  }
}

# // ------------- Instance Group A
# resource "google_compute_instance_template" "tmpl_instance_group_1" {
#   name                 = "${random_id.id.hex}-ig-1"
#   project              = data.google_project.producer.project_id
#   description          = "SG instance group of non-preemptible hosts"
#   instance_description = "description assigned to instances"
#   machine_type         = "e2-medium"
#   can_ip_forward       = false
#   tags                 = ["lb-backend"]
#   region               = var.region_a 

#   scheduling {
#     preemptible       = false
#     automatic_restart = false

#   }
  
#   shielded_instance_config {
#     enable_integrity_monitoring = true
#     enable_secure_boot          = true
#     enable_vtpm                 = true
#   }

#   // Create a new boot disk from an image
#   disk {
#     source_image = "debian-cloud/debian-11"
#     auto_delete  = true
#     boot         = true
#   }

#   network_interface {
#     network            = google_compute_network.producer_vpc_network.name
#     subnetwork         = google_compute_subnetwork.producer_sb_subnet_a.name
#     subnetwork_project = data.google_project.producer.project_id
#     # access_config {
#     #   // Ephemeral public IP
#     # }
#   }

#   metadata = {
#     startup-script-url = "https://raw.githubusercontent.com/astianseb/sg-helper-scripts/refs/heads/main/startup.sh"
# #    startup-script-url = "gs://cloud-training/gcpnet/ilb/startup.sh"
#   }
# }

# #MIG-a
# resource "google_compute_instance_group_manager" "grp_instance_group_1" {
#   name               = "${random_id.id.hex}-igm-1"
#   project            = data.google_project.producer.project_id
#   base_instance_name = "${random_id.id.hex}-mig-a"
#   zone               = local.zone-a
#   version {
#     instance_template = google_compute_instance_template.tmpl_instance_group_1.id
#   }

#   auto_healing_policies {
#     health_check      = google_compute_health_check.tcp_health_check.id
#     initial_delay_sec = 300
#   }
#   named_port {
#     name = "${random_id.id.hex}-https"
#     port = 443
#   }
# }

# resource "google_compute_autoscaler" "obj_my_autoscaler_a" {
#   name    = "${random_id.id.hex}-autoscaler-a"
#   project = data.google_project.producer.project_id
#   zone    = local.zone-a
#   target  = google_compute_instance_group_manager.grp_instance_group_1.id

#   autoscaling_policy {
#     max_replicas    = 2
#     min_replicas    = 1
#     cooldown_period = 45

#     cpu_utilization {
#       target = 0.8
#     }
#   }
# }


# //----------------Instance Group B

# resource "google_compute_instance_template" "tmpl_instance_group_2" {
#   name                 = "${random_id.id.hex}-ig-2"
#   project              = data.google_project.producer.project_id
#   description          = "SG instance group of non preemptible hosts"
#   instance_description = "description assigned to instances"
#   machine_type         = "e2-medium"
#   can_ip_forward       = false
#   tags                 = ["lb-backend"]
#   region               = var.region_b

#   scheduling {
#     preemptible       = false
#     automatic_restart = false

#   }

#   shielded_instance_config {
#     enable_integrity_monitoring = true
#     enable_secure_boot          = true
#     enable_vtpm                 = true
#   }

#   disk {
#     source_image = "debian-cloud/debian-11"
#     auto_delete  = true
#     boot         = true
#   }

#   network_interface {
#     network            = google_compute_network.producer_vpc_network.name
#     subnetwork         = google_compute_subnetwork.producer_sb_subnet_b.name
#     subnetwork_project = data.google_project.producer.project_id
#      # access_config {
#     #   // Ephemeral public IP
#     # }
#   }

#   metadata = {
#     startup-script-url = "https://raw.githubusercontent.com/astianseb/sg-helper-scripts/refs/heads/main/startup.sh"
# #    startup-script-url = "gs://cloud-training/gcpnet/ilb/startup.sh"
#   }
# }

# resource "google_compute_instance_group_manager" "grp_instance_group_2" {
#   name               = "${random_id.id.hex}-igm-2"
#   project            = data.google_project.producer.project_id
#   base_instance_name = "${random_id.id.hex}-mig-b"
#   zone               = local.zone-b
  
#   version {
#     instance_template = google_compute_instance_template.tmpl_instance_group_2.id
#   }

#   auto_healing_policies {
#     health_check      = google_compute_health_check.tcp_health_check.id
#     initial_delay_sec = 300
#   }
#   named_port {
#     name = "${random_id.id.hex}-https"
#     port = 443
#   }
# }

# resource "google_compute_autoscaler" "obj_my_autoscaler_b" {
#   name    = "${random_id.id.hex}-autoscaler-b"
#   project = data.google_project.producer.project_id
#   zone    = local.zone-b
#   target  = google_compute_instance_group_manager.grp_instance_group_2.id

#   autoscaling_policy {
#     max_replicas    = 2
#     min_replicas    = 1
#     cooldown_period = 45

#     cpu_utilization {
#       target = 0.8
#     }
#   }
# }



# # forwarding rule
# resource "google_compute_global_forwarding_rule" "app_forwarding_rule" {
#   name                  = "${random_id.id.hex}-fr"
#   provider              = google-beta
#   project               = data.google_project.producer.project_id
#   ip_protocol           = "TCP"
#   load_balancing_scheme = "EXTERNAL_MANAGED"
#   port_range            = "443"
#   target                = google_compute_target_https_proxy.producer.id
#  # ip_address            = google_compute_address.default.id
# }

# # http proxy
# resource "google_compute_target_https_proxy" "producer" {
#   name     = "${random_id.id.hex}-https-proxy"
#   provider = google-beta
#   project  = data.google_project.producer.project_id
#   url_map  = google_compute_url_map.producer.id
  
#   ssl_certificates = [google_compute_ssl_certificate.producer.self_link]

# }

# # url map
# resource "google_compute_url_map" "producer" {
#   name            = "${random_id.id.hex}-url-map"
#   provider        = google-beta
#   project         = data.google_project.producer.project_id
#   default_service = google_compute_backend_service.app_backend.id
# }


# # HTTP regional load balancer (envoy based)
# resource "google_compute_backend_service" "app_backend" {
#   name                     = "${random_id.id.hex}-app-bs"
#   provider                 = google-beta
#   project                  = data.google_project.producer.project_id
# #  protocol                 = "HTTP"
# #  port_name                = "my-port"
#   protocol                 = "HTTPS"
#   port_name                = "${random_id.id.hex}-https"
#   load_balancing_scheme    = "EXTERNAL_MANAGED"
#   timeout_sec              = 10
#   health_checks            = [google_compute_health_check.tcp_health_check.id]
#   backend {
#     group           = google_compute_instance_group_manager.grp_instance_group_1.instance_group
#     balancing_mode  = "UTILIZATION"
#     capacity_scaler = 1.0
#   }
#   backend {
#     group           = google_compute_instance_group_manager.grp_instance_group_2.instance_group
#     balancing_mode  = "UTILIZATION"
#     capacity_scaler = 1.0
#   }
# }



############### SIEGE HOST #####################

# Instance to host siege (testing tool for LB)
# usage: siege -i --concurrent=50 http://<lb-ip>
#


resource "google_service_account" "siege_sa" {
  account_id = "${random_id.id.hex}-siege-sa"
}

resource "google_compute_instance" "siege_host_region_a" {
  provider = google-beta
  name         = "${random_id.id.hex}-siege-reg-a"
  machine_type = "e2-medium"
  zone         = local.zone-a
  project      = data.google_project.producer.project_id

  allow_stopping_for_update = true

  tags = ["siege"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    network    = google_compute_network.producer_vpc_network.name
    subnetwork = google_compute_subnetwork.producer_sb_subnet_a.self_link
  }
  service_account {
    email  = google_service_account.siege_sa.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    preemptible       = true
    automatic_restart = false
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  metadata = {
    enable-oslogin = true
    enable-workload-certificate = true
  }

  partner_metadata = {
    "wc.compute.googleapis.com" = jsonencode({
     entries = {
        certificate-issuance-config = {
          primary_certificate_authority_config = {
              certificate_authority_config = {
                 ca_pool = "${google_privateca_ca_pool.producer_ca_pool.id}"
              }
           },
           key_algorithm = "ecdsa-p256"
        },
        trust-config = {
           "${google_iam_workload_identity_pool.sg.workload_identity_pool_id}.global.${data.google_project.producer.number}.workload.id.goog" = {
               trust_anchors = [{
                  ca_pool = "${google_privateca_ca_pool.producer_ca_pool.id}"
                }]
           }
     }
  }}),

    "iam.googleapis.com" = jsonencode({
      entries = {
         workload-identity = "spiffe://${google_iam_workload_identity_pool.sg.workload_identity_pool_id}.global.${data.google_project.producer.number}.workload.id.goog/ns/${google_iam_workload_identity_pool_managed_identity.sg.workload_identity_pool_namespace_id}/sa/${google_iam_workload_identity_pool_managed_identity.sg.workload_identity_pool_managed_identity_id}"
     }
    })

  }

  #
  # gcloud beta compute instances  describe sg-0aab406a-siege-reg-a --zone=europe-west1-b --format="yaml(partnerMetadata)" --view=full
  #
  #
  #



  metadata_startup_script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y siege
     EOF1

}


# resource "google_compute_instance" "siege_host_region_b" {
#   name         = "${random_id.id.hex}-siege-reg-b"
#   machine_type = "e2-medium"
#   zone         = local.zone-b
#   project      = data.google_project.producer.project_id

#   tags = ["siege"]

#   boot_disk {
#     initialize_params {
#       image = "debian-cloud/debian-11"
#     }
#   }

#   network_interface {
#     network    = google_compute_network.producer_vpc_network.name
#     subnetwork = google_compute_subnetwork.producer_sb_subnet_b.self_link
#   }

#   scheduling {
#     preemptible       = true
#     automatic_restart = false
#   }

#   shielded_instance_config {
#     enable_integrity_monitoring = true
#     enable_secure_boot          = true
#     enable_vtpm                 = true
#   }

#   metadata = {
#     enable-oslogin = true
#   }


#   metadata_startup_script = <<-EOF1
#       #! /bin/bash
#       set -euo pipefail

#       export DEBIAN_FRONTEND=noninteractive
#       apt-get update
#       apt-get install -y siege
#      EOF1

# }
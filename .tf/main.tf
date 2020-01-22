
resource "google_project" "devrel-services" {
  billing_account = var.billing_account
  folder_id       = var.folder_id
  name            = var.project_name
  project_id      = var.project_id
  labels = {
    env  = "prod"
    team = "cloud_devrel_infra"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_global_address" "samplr_ip" {
  name = "samplr-ip"
}

data "google_compute_global_address" "samplr_address" {
  name = "samplr-ip"

  depends_on = [
    google_compute_global_address.samplr_ip
  ]
}

resource "google_endpoints_service" "samplr_grpc_service" {
  service_name         = "samplr.endpoints.${var.project_id}.cloud.goog"
  grpc_config          = <<-EOT
  type: google.api.Service
  config_version: 3

  name: samplr.endpoints.${var.project_id}.cloud.goog
  title: samplr gRPC API (TYPE)

  apis:
  - name: drghs.v1.SampleService

  endpoints:
  - name: samplr.endpoints.${var.project_id}.cloud.goog
    target: "${data.google_compute_global_address.samplr_address.address}"
  EOT
  protoc_output_base64 = filebase64("../drghs/v1/api_descriptor.pb")

  depends_on = [
    data.google_compute_global_address.samplr_address,
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_global_address" "maintner_ip" {
  name = "maintner-ip"
}

data "google_compute_global_address" "maintner_address" {
  name = "maintner-ip"
  depends_on = [
    google_compute_global_address.maintner_ip,
  ]
}

# TODO: Uncomment this when maintner gets the gRPC service
#
#resource "google_endpoints_service" "maintner_grpc_service" {
#  service_name         = "drghs.endpoints.${var.project_id}.cloud.goog"
#  grpc_config          = <<-EOT
#  type: google.api.Service
#  config_version: 3
#
#  name: samplr.endpoints.${var.project_id}.cloud.goog
#  title: DevRel GitHub Services API (TYPE)
#
#  apis:
#  - name: drghs.v1.IssueService
#
#  endpoints:
#  - name: drghs.endpoints.${var.project_id}.cloud.goog
#    target: "${data.google_compute_global_address.samplr_address.address}"
#  EOT
#  protoc_output_base64 = filebase64("../drghs/v1/api_descriptor.pb")
#
#  depends_on = [
#    data.google_compute_global_address.maintner_ip,
#  ]
#
#  lifecycle {
#    prevent_destroy = true
#  }
#}

# TODO: Endpoints for MGHP
#
resource "google_compute_global_address" "mghp_ip" {
  name = "magic-github-proxy-ip"
}

data "google_compute_global_address" "mghp_address" {
  name = "magic-github-proxy-ip"
  depends_on = [
    google_compute_global_address.mghp_ip,
  ]
}


resource "google_storage_bucket" "maintner_bucket" {
  name     = "${var.maintner_bucket_name}"
  location = "US"
}

resource "google_project_iam_custom_role" "maintner_sprvsr_bucket_creator" {
  role_id     = "maintner_sprvsr_bucket_creator"
  title       = "Maintner Supervisor Bucket Creator"
  description = "Used by maintner-sprvsr to create buckets"
  permissions = [
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.get",
    "storage.buckets.list",
    "storage.objects.create",
    "storage.objects.delete",
    "storage.objects.list",
  ]
}

resource "google_service_account" "maintner_service_account" {
  account_id   = "maintnerd"
  display_name = "Maintnerd Service Account"
  description  = "Service Account used by Maintner service"
}

resource "google_project_iam_member" "maintner_account_iam" {
  role   = "projects/${var.project_id}/roles/${google_project_iam_custom_role.maintner_sprvsr_bucket_creator.role_id}"
  member = "serviceAccount:${google_service_account.maintner_service_account.email}"
}

# TODO: Custom Role for Samplr

resource "google_service_account" "samplr_service_account" {
  account_id   = "samplr"
  display_name = "Samplr Service Account"
  description  = "Service Account used by Samplr service"
}

# TODO: Service Account for Magic GitHub Proxy
#

resource "google_container_cluster" "devrel-services" {
  name     = "devrel-services"
  location = var.region

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}


resource "google_container_node_pool" "primary_nodes" {
  name               = "adjust-scope"
  location           = var.region
  cluster            = google_container_cluster.devrel-services.name
  initial_node_count = 10

  node_config {
    preemptible  = false
    machine_type = "n1-standard-2"

    metadata = {
      disable-legacy-endpoints = "true"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }

  autoscaling {
    min_node_count = 6
    max_node_count = 40
  }

  management {
    auto_repair  = true
    auto_upgrade = false
  }
}

resource "google_container_node_pool" "samplr_nodes" {
  name               = "samplr-nodes"
  location           = var.region
  cluster            = google_container_cluster.devrel-services.name
  initial_node_count = 1

  node_config {
    preemptible  = false
    machine_type = "n1-standard-2"

    metadata = {
      disable-legacy-endpoints = "true"
      # The idea of this is to pair it with a pod affinity label
      # for the samplr pods. This way we can keep samplr and maintner
      # application pods in different pools to help with node upgrades etc.
      drghs-node-type = "samplr"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 40
  }

  management {
    auto_repair  = true
    auto_upgrade = false
  }
}

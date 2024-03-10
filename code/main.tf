terraform {
  required_version = ">=1.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.80.0"
    }
    google-beta = "~> 3.9"
  }
}

#reference to our project build with /cicd
data "google_project" "target" {
  project_id = var.project_id
}

locals {
  project_id    = data.google_project.target.project_id
  cloudbuild_sa = "serviceAccount:${data.google_project.target.number}@cloudbuild.gserviceaccount.com"
  gar_repo_name = format("%s-%s", "prj", "containers") #container artifact registry repository
  service_name  = var.service_name
  location      = "us-central1"

  # services particular to this
  services = [
    "secretmanager.googleapis.com",
    "run.googleapis.com",
  "artifactregistry.googleapis.com"]
}


# enable services
resource "google_project_service" "services" {
  for_each           = toset(local.services)
  project            = data.google_project.target.project_id
  service            = each.value
  disable_on_destroy = false
}

# dedicated service account for our cloudrun service
# so we don't use the default compute engine service account
resource "google_service_account" "cloudrun_service_identity" {
  project    = local.project_id
  account_id = "${local.service_name}-svc-account"
}


/**
cloud build container
**/

resource "null_resource" "cloudbuild_cloudrun_container" {
  # build if source changes
  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset(path.root, "source/**") : filesha1(f)]))
  }


  provisioner "local-exec" {
    command = <<EOT
      gcloud builds submit ./source/ --project ${local.project_id} --config=./source/cloudbuild.yaml --substitutions=_SERVICE_NAME=${local.service_name}
  EOT
  }
}


# set a project policy to allow allUsers invoke
resource "google_project_organization_policy" "services_policy" {
  project    = local.project_id
  constraint = "iam.allowedPolicyMemberDomains"

  list_policy {
    allow {
      all = true
    }
  }
}

resource "google_cloud_run_service" "default" {
  name                       = local.service_name
  location                   = local.location
  project                    = local.project_id
  autogenerate_revision_name = true

  template {
    spec {
      service_account_name = google_service_account.cloudrun_service_identity.email
      containers {
        image = "${local.location}-docker.pkg.dev/${local.project_id}/${local.gar_repo_name}/${local.service_name}"
        env {
          name  = "PROJECT_ID"
          value = local.project_id
        }
      }
    }
  }

}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "noauth" {
  location = google_cloud_run_service.default.location
  project  = local.project_id
  service  = google_cloud_run_service.default.name

  policy_data = data.google_iam_policy.noauth.policy_data
}


# compute global address as a target for an A record
resource "google_compute_global_address" "cloud_run_lb_address" {
  project = local.project_id
  name    = "${local.service_name}-cloudrun-lb-address"
}


# SSL cert
resource "google_compute_managed_ssl_certificate" "default" {
  provider = google-beta
  project  = local.project_id

  name = "${local.service_name}-cert"
  managed {
    domains = ["${local.service_name}.${var.domain_name}"]
  }
}


# forwarding rule -> target http proxy -> url map -> NEG -> backend service -> cloud-run.
# forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "${local.service_name}-forwarding-rule"
  project               = local.project_id
  provider              = google-beta
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  target                = google_compute_target_https_proxy.default.id
  ip_address            = google_compute_global_address.cloud_run_lb_address.id
}

# url map
resource "google_compute_url_map" "default" {
  name            = "${local.service_name}-url-map"
  project         = local.project_id
  provider        = google-beta
  default_service = google_compute_backend_service.default.id
}

# https proxy
resource "google_compute_target_https_proxy" "default" {
  name    = "${local.service_name}-https-proxy"
  project = local.project_id

  url_map = google_compute_url_map.default.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.default.id
  ]
}


resource "google_compute_region_network_endpoint_group" "cloudrun_neg" {
  provider              = google-beta
  project               = local.project_id
  name                  = "${local.service_name}-neg"
  network_endpoint_type = "SERVERLESS"
  region                = local.location
  cloud_run {
    service = google_cloud_run_service.default.name
  }
}

resource "google_compute_backend_service" "default" {
  name    = "${local.service_name}-backend"
  project = local.project_id

  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 30

  backend {
    group = google_compute_region_network_endpoint_group.cloudrun_neg.id
  }
}


#http redirect to https
resource "google_compute_url_map" "https_redirect" {
  name    = "${local.service_name}-https-redirect"
  project = local.project_id
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "https_redirect" {
  name    = "${local.service_name}-http-proxy-redirect"
  project = local.project_id
  url_map = google_compute_url_map.https_redirect.id
}

resource "google_compute_global_forwarding_rule" "https_redirect" {
  name       = "${local.service_name}-lb-http-redirect"
  project    = local.project_id
  target     = google_compute_target_http_proxy.https_redirect.id
  port_range = "80"
  ip_address = google_compute_global_address.cloud_run_lb_address.address
}

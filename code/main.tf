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

resource "google_cloud_run_v2_service" "default" {
  name     = local.service_name
  location = local.location
  project  = local.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  # template {
  #   spec {
  #     service_account_name = google_service_account.cloudrun_service_identity.email
  #     containers {
  #       image = "${local.location}-docker.pkg.dev/${local.project_id}/${local.gar_repo_name}/${local.service_name}"
  #       env {
  #         name  = "PROJECT_ID"
  #         value = local.project_id
  #       }
  #     }
  #   }
  # }
  template {

    containers {
      image = "${local.location}-docker.pkg.dev/${local.project_id}/${local.gar_repo_name}/${local.service_name}"
      env {
        name  = "PROJECT_ID"
        value = local.project_id
      }

    }
    service_account = google_service_account.cloudrun_service_identity.email
  }

}

resource "google_cloud_run_v2_service_iam_member" "noauth" {
  location = google_cloud_run_v2_service.default.location
  name     = google_cloud_run_v2_service.default.name
  project  = local.project_id
  role     = "roles/run.invoker"
  member   = "allUsers"
}


resource "google_cloud_run_domain_mapping" "default" {
  name     = var.domain_name
  location = google_cloud_run_v2_service.default.location
  project  = local.project_id
  metadata {
    namespace = local.project_id
  }
  spec {
    route_name = google_cloud_run_v2_service.default.name
  }
}

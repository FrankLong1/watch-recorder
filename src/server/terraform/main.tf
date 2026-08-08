locals {
  service_enabled       = var.image != ""
  database_user         = trimsuffix(google_service_account.ingest.email, ".gserviceaccount.com")
  watcher_enabled       = var.watcher_service_account_email != ""
  watcher_database_user = trimsuffix(var.watcher_service_account_email, ".gserviceaccount.com")
}

# The instance belongs to a separate, private Terraform configuration. Reading it
# through a data source means this configuration can attach a database and a
# service to it without ever being able to modify or destroy it.
data "google_sql_database_instance" "shared" {
  project = var.project_id
  name    = var.sql_instance_name
}

resource "google_project_service" "required" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- Database -----------------------------------------------------------------

# Its own database rather than a schema in the neighbour, so the blast radius of
# anything WristMemo does stops at the database boundary.
resource "google_sql_database" "wristmemo" {
  project  = var.project_id
  name     = var.database_name
  instance = data.google_sql_database_instance.shared.name
}

# Schema owner, used only by scripts/migrate.sh. Kept separate from the ingest
# identity so the running service can never alter its own schema, and separate
# from the neighbour's migrator so neither project's migrations can touch the
# other's tables. Keyless — the operator impersonates it for the duration of a
# migration.
resource "google_service_account" "migrator" {
  project      = var.project_id
  account_id   = var.migrator_service_account_id
  display_name = "WristMemo migrator"
  description  = "Keyless schema owner for the wristmemo database. Never used by the running service."
}

resource "google_project_iam_member" "migrator_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.migrator.member
}

resource "google_project_iam_member" "migrator_cloudsql_instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = google_service_account.migrator.member
}

resource "google_service_account_iam_member" "operator_impersonates_migrator" {
  service_account_id = google_service_account.migrator.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${var.operator_iam_user}"
}

resource "google_sql_user" "migrator" {
  project        = var.project_id
  instance       = data.google_sql_database_instance.shared.name
  name           = trimsuffix(google_service_account.migrator.email, ".gserviceaccount.com")
  type           = "CLOUD_IAM_SERVICE_ACCOUNT"
  database_roles = ["cloudsqlsuperuser"]

  deletion_policy = "ABANDON"
}

resource "google_service_account" "ingest" {
  project      = var.project_id
  account_id   = var.ingest_service_account_id
  display_name = "WristMemo ingest"
  description  = "Cloud Run identity for WristMemo transcript ingest. No access to the agent inbox."
}

resource "google_project_iam_member" "ingest_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.ingest.member
}

resource "google_project_iam_member" "ingest_cloudsql_instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = google_service_account.ingest.member
}

# Deliberately no database_roles here. The wristmemo_ingest role is created by
# migration 0001, which cannot run until this user exists — so the migration
# performs the GRANT instead and the ordering stays acyclic.
resource "google_sql_user" "ingest" {
  project  = var.project_id
  instance = data.google_sql_database_instance.shared.name
  name     = local.database_user
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

# The Cloud Workstation owns the watcher process, so it receives its own
# database identity. SQL privileges are deliberately granted by migration 0002
# rather than here: Terraform must not own objects inside the application schema.
resource "google_project_iam_member" "watcher_cloudsql_client" {
  count = local.watcher_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${var.watcher_service_account_email}"
}

resource "google_project_iam_member" "watcher_cloudsql_instance_user" {
  count = local.watcher_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${var.watcher_service_account_email}"
}

resource "google_sql_user" "watcher" {
  count = local.watcher_enabled ? 1 : 0

  project  = var.project_id
  instance = data.google_sql_database_instance.shared.name
  name     = local.watcher_database_user
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}


# --- Secrets ------------------------------------------------------------------

# Containers only. Values are set outside Terraform so they never enter state,
# a plan, or a log.
resource "google_secret_manager_secret" "openai_api_key" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-openai-api-key"

  replication {
    auto {}
  }

  deletion_protection = true
  depends_on          = [google_project_service.required]
}

resource "google_secret_manager_secret" "ingest_token" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-ingest-token"

  replication {
    auto {}
  }

  deletion_protection = true
  depends_on          = [google_project_service.required]
}

# Read-only token for the remote workstation's metadata feed. It is deliberately
# separate from the phone ingest token so a leaked watcher can never upload audio.
resource "google_secret_manager_secret" "watcher_token" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-watcher-token"

  replication {
    auto {}
  }

  deletion_protection = true
  depends_on          = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "ingest_secrets" {
  for_each = {
    openai  = google_secret_manager_secret.openai_api_key.secret_id
    token   = google_secret_manager_secret.ingest_token.secret_id
    watcher = google_secret_manager_secret.watcher_token.secret_id
  }

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.ingest.member
}

# --- Image --------------------------------------------------------------------

resource "google_artifact_registry_repository" "ingest" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Private images for WristMemo ingest."

  depends_on = [google_project_service.required]
}

# --- Service ------------------------------------------------------------------

resource "google_cloud_run_v2_service" "ingest" {
  count = local.service_enabled ? 1 : 0

  project  = var.project_id
  name     = var.service_name
  location = var.region

  # Called by a background daemon on a phone, so IAP is not usable here — it
  # expects an interactive Google sign-in. Authentication is the bearer token
  # checked in the application.
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  labels = {
    component  = "wristmemo"
    managed-by = "terraform"
  }

  template {
    service_account = google_service_account.ingest.email
    # A long memo plus a slow model still has to finish inside one request.
    timeout = "600s"

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"

      cloud_sql_instance {
        instances = [data.google_sql_database_instance.shared.connection_name]
      }
    }

    containers {
      image = var.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 3
        period_seconds        = 5
        failure_threshold     = 12

        http_get {
          path = "/readyz"
          port = 8080
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name  = "CLOUD_SQL_CONNECTION_NAME"
        value = data.google_sql_database_instance.shared.connection_name
      }
      env {
        name  = "DATABASE_NAME"
        value = google_sql_database.wristmemo.name
      }
      env {
        name  = "DATABASE_USER"
        value = google_sql_user.ingest.name
      }
      env {
        name  = "OPENAI_MODEL"
        value = var.openai_model
      }
      env {
        name  = "WRISTMEMO_USER_ID"
        value = var.user_id
      }
      env {
        name = "OPENAI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.openai_api_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "WRISTMEMO_INGEST_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.ingest_token.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "WRISTMEMO_WATCHER_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.watcher_token.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
      error_message = "image must use an immutable sha256 digest."
    }
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.ingest_cloudsql_client,
    google_project_iam_member.ingest_cloudsql_instance_user,
    google_secret_manager_secret_iam_member.ingest_secrets,
    google_sql_user.ingest,
  ]
}

# The phone authenticates with the bearer token, not with Google IAM, so the
# service must accept unauthenticated requests at the platform layer.
resource "google_cloud_run_v2_service_iam_member" "public" {
  count = local.service_enabled ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.ingest[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

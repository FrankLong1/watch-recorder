output "instance_connection_name" {
  description = "Cloud SQL connector target for the migration proxy."
  value       = data.google_sql_database_instance.shared.connection_name
}

output "database_name" {
  value = google_sql_database.wristmemo.name
}

output "ingest_database_user" {
  description = "Pass to scripts/migrate.sh as INGEST_DATABASE_USER so it receives the wristmemo_ingest role."
  value       = google_sql_user.ingest.name
}

output "ingest_service_account" {
  value = google_service_account.ingest.email
}

output "secret_ids" {
  description = "Set both values outside Terraform with `gcloud secrets versions add`."
  value = {
    openai_api_key = google_secret_manager_secret.openai_api_key.secret_id
    ingest_token   = google_secret_manager_secret.ingest_token.secret_id
  }
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.ingest.repository_id}"
}

output "service_url" {
  description = "Empty until an image digest is supplied."
  value       = local.service_enabled ? google_cloud_run_v2_service.ingest[0].uri : ""
}

output "migrator_database_user" {
  description = "Impersonate this to run scripts/migrate.sh; it owns the schema and nothing else."
  value = {
    service_account = google_service_account.migrator.email
    database_user   = google_sql_user.migrator.name
  }
}

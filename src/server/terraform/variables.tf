variable "project_id" {
  description = "GCP project that owns the shared Cloud SQL instance. There is intentionally no default."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must be set."
  }
}

variable "region" {
  description = "Region for Cloud Run and Artifact Registry. Must match the Cloud SQL instance's region."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "region must be set."
  }
}

variable "sql_instance_name" {
  description = <<-EOT
    Name of the EXISTING Cloud SQL instance to attach to. This configuration
    reads the instance through a data source and never manages it, so that
    instance's own Terraform state remains the single owner. There is
    intentionally no default — this repo is public.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.sql_instance_name)) > 0
    error_message = "sql_instance_name must be set."
  }
}

variable "name_prefix" {
  description = "Prefix for every resource this configuration creates."
  type        = string
  default     = "wristmemo"
}

variable "database_name" {
  description = "Dedicated PostgreSQL database, separate from the neighbour's."
  type        = string
  default     = "wristmemo"
}

variable "operator_iam_user" {
  description = "Human IAM user permitted to impersonate the migrator when running migrations."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.operator_iam_user))
    error_message = "operator_iam_user must be an email address."
  }
}

variable "migrator_service_account_id" {
  description = "Keyless schema-owner identity used only by scripts/migrate.sh."
  type        = string
  default     = "wristmemo-migrator"
}

variable "ingest_service_account_id" {
  description = "Least-privilege Cloud Run identity for the ingest service."
  type        = string
  default     = "wristmemo-ingest"
}

variable "watcher_service_account_email" {
  description = <<-EOT
    Google service-account identity used by the remote watcher. It receives a
    short-lived ID token from the metadata server; no service-account key or
    shared watcher secret exists.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.watcher_service_account_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+[.]gserviceaccount[.]com$", var.watcher_service_account_email))
    error_message = "watcher_service_account_email must be a service account email or empty."
  }
}

variable "google_watcher_service_accounts" {
  description = "Additional Google service-account emails allowed to read the metadata-only watcher feed."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for email in var.google_watcher_service_accounts :
      can(regex("^[^@[:space:]]+@[^@[:space:]]+[.]gserviceaccount[.]com$", email))
    ])
    error_message = "Every google_watcher_service_accounts entry must be a service-account email."
  }
}

variable "google_oauth_client_id" {
  description = "Google OAuth web/server client ID used as the exact ID-token audience."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+-[A-Za-z0-9_-]+[.]apps[.]googleusercontent[.]com$", var.google_oauth_client_id))
    error_message = "google_oauth_client_id must be a Google OAuth client ID."
  }
}

variable "google_allowed_user_subjects" {
  description = "Immutable Google OIDC subject identifiers allowed to upload memos."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.google_allowed_user_subjects) > 0 && alltrue([for subject in var.google_allowed_user_subjects : length(trimspace(subject)) > 0])
    error_message = "google_allowed_user_subjects must contain at least one non-empty subject."
  }
}

variable "service_name" {
  description = "Cloud Run service name."
  type        = string
  default     = "wristmemo-ingest"
}

variable "repository_id" {
  description = "Artifact Registry repository for the ingest image."
  type        = string
  default     = "wristmemo"
}

variable "image" {
  description = <<-EOT
    Immutable ingest image digest. Empty keeps Cloud Run disabled while the
    database, identity, secrets and repository are provisioned on a first apply.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.image == "" || can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must use an immutable sha256 digest."
  }
}

variable "openai_model" {
  description = "OpenAI transcription model. Changeable without a code change."
  type        = string
  default     = "gpt-4o-transcribe"
}

variable "user_id" {
  description = "Deprecated and ignored. Retained temporarily so older private tfvars still load."
  type        = string
  default     = "default-user"
}

variable "max_instances" {
  description = "Cloud Run ceiling. Voice memos arrive one at a time; this only bounds a runaway."
  type        = number
  default     = 3
}

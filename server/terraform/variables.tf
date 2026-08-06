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
    reads the instance through a data source and never manages it, so the
    agent-inbox Terraform state remains the single owner.
  EOT
  type        = string
  default     = "demo-agent-inbox-postgres"
}

variable "name_prefix" {
  description = "Prefix for every resource this configuration creates."
  type        = string
  default     = "wristmemo"
}

variable "database_name" {
  description = "Dedicated PostgreSQL database, separate from the agent inbox's."
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
  description = "Value written to memos.user_id until real per-user auth exists."
  type        = string
  default     = "frank"
}

variable "max_instances" {
  description = "Cloud Run ceiling. Voice memos arrive one at a time; this only bounds a runaway."
  type        = number
  default     = 3
}

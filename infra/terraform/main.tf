locals {
  api_runtime_roles = toset([
    "roles/datastore.user",
    "roles/aiplatform.user",
    "roles/dlp.user",
    "roles/modelarmor.user",
    "roles/logging.logWriter"
  ])
  mcp_runtime_roles = toset([
    "roles/aiplatform.user",
    "roles/logging.logWriter"
  ])
  adk_runtime_roles = toset([
    "roles/aiplatform.user",
    "roles/modelarmor.user",
    "roles/logging.logWriter"
  ])
}

resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "firestore.googleapis.com",
    "secretmanager.googleapis.com",
    "aiplatform.googleapis.com",
    "dlp.googleapis.com",
    "modelarmor.googleapis.com"
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "api_runtime" {
  account_id   = "couponcok-api-runtime"
  display_name = "CouponCock API runtime (least privilege)"
}

resource "google_service_account" "mcp_runtime" {
  account_id   = "couponcok-mcp-runtime"
  display_name = "CouponCock MCP runtime (least privilege)"
}

resource "google_service_account" "adk_runtime" {
  account_id   = "couponcok-adk-runtime"
  display_name = "CouponCock ADK runtime (least privilege)"
}

resource "google_service_account" "store_sync_runtime" {
  account_id   = "couponcok-store-sync"
  display_name = "CouponCock public-store sync job"
}

resource "google_service_account" "scheduler" {
  account_id   = "couponcok-scheduler"
  display_name = "CouponCock scheduler: run store-sync only"
}

resource "google_project_iam_member" "api_runtime_roles" {
  for_each = local.api_runtime_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.api_runtime.email}"
}

resource "google_project_iam_member" "mcp_runtime_roles" {
  for_each = local.mcp_runtime_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.mcp_runtime.email}"
}

resource "google_project_iam_member" "adk_runtime_roles" {
  for_each = local.adk_runtime_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.adk_runtime.email}"
}

resource "google_project_iam_member" "store_sync_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.store_sync_runtime.email}"
}

resource "google_project_iam_member" "store_sync_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.store_sync_runtime.email}"
}

resource "google_project_iam_custom_role" "scheduler_store_sync_runner" {
  role_id     = "couponcokStoreSyncRunner"
  title       = "CouponCock Store Sync Runner"
  description = "Can run only existing Cloud Run Jobs; no deployment or service mutation permissions."
  permissions = ["run.jobs.run"]
  stage       = "GA"
}

resource "google_project_iam_member" "scheduler_store_sync_runner" {
  project = var.project_id
  role    = google_project_iam_custom_role.scheduler_store_sync_runner.name
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_storage_bucket_iam_member" "api_benefit_read" {
  bucket = var.benefits_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.api_runtime.email}"
}

resource "google_storage_bucket_iam_member" "mcp_benefit_read" {
  bucket = var.benefits_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.mcp_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "api_data_go" {
  project   = var.project_id
  secret_id = var.data_go_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "api_pseudonym" {
  project   = var.project_id
  secret_id = var.pseudonym_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api_runtime.email}"
}

# The API only reads the token used to invoke its private ADK service. It does not receive
# the MCP token or any Maps credential.
resource "google_secret_manager_secret_iam_member" "api_adk_token" {
  project   = var.project_id
  secret_id = var.adk_token_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "mcp_data_go" {
  project   = var.project_id
  secret_id = var.data_go_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mcp_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "mcp_token" {
  project   = var.project_id
  secret_id = var.mcp_token_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mcp_runtime.email}"
}

# The MCP runtime is the only workload that calls the configured Maps provider fallback.
resource "google_secret_manager_secret_iam_member" "mcp_google_maps" {
  project   = var.project_id
  secret_id = var.google_maps_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mcp_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "adk_tokens" {
  for_each   = toset([var.mcp_token_secret_name, var.adk_token_secret_name])
  project    = var.project_id
  secret_id  = each.value
  role       = "roles/secretmanager.secretAccessor"
  member     = "serviceAccount:${google_service_account.adk_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "store_sync_data_go" {
  project   = var.project_id
  secret_id = var.data_go_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.store_sync_runtime.email}"
}

# The public mobile API stays private. Only the declared API Gateway backend identity can invoke it.
resource "google_cloud_run_v2_service_iam_member" "gateway_invokes_api" {
  project  = var.project_id
  location = var.region
  name     = var.api_service_name
  role     = "roles/run.invoker"
  member   = var.gateway_invoker_member
}

resource "google_cloud_run_v2_service_iam_member" "api_invokes_adk" {
  project  = var.project_id
  location = var.region
  name     = var.adk_service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.api_runtime.email}"
}

resource "google_cloud_run_v2_service_iam_member" "adk_invokes_mcp" {
  project  = var.project_id
  location = var.region
  name     = var.mcp_service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.adk_runtime.email}"
}

resource "google_cloud_run_v2_job" "store_sync" {
  name     = "couponcok-store-sync"
  location = var.region
  template {
    template {
      service_account = google_service_account.store_sync_runtime.email
      timeout         = "1800s"
      max_retries     = 1
      containers {
        image   = var.api_image
        command = ["node"]
        args    = ["dist/jobs/syncStoreDirectory.js"]
        env { name = "VERTEX_PROJECT_ID" value = var.project_id }
        env { name = "STORE_SYNC_SCOPE" value = "suwon" }
        env {
          name = "DATA_GO_KR_SERVICE_KEY"
          value_source { secret_key_ref { secret = var.data_go_secret_name version = "latest" } }
        }
      }
    }
  }
  depends_on = [google_project_service.required]
}

resource "google_cloud_scheduler_job" "store_sync_daily" {
  name        = "couponcok-store-sync-daily"
  description = "Runs the read-only public store directory refresh once per day."
  schedule    = var.scheduler_cron
  time_zone   = var.scheduler_time_zone
  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.store_sync.name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")
    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

output "runtime_service_accounts" {
  value = {
    api        = google_service_account.api_runtime.email
    mcp        = google_service_account.mcp_runtime.email
    adk        = google_service_account.adk_runtime.email
    store_sync = google_service_account.store_sync_runtime.email
  }
}

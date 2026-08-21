variable "project_id" { type = string }
variable "region" { type = string, default = "asia-northeast3" }
variable "api_service_name" { type = string, default = "coupon-pilot-api" }
variable "mcp_service_name" { type = string, default = "couponcok-mcp" }
variable "adk_service_name" { type = string, default = "couponcok-adk" }
variable "api_image" {
  type        = string
  description = "Immutable Artifact Registry image URI for the store-sync Cloud Run Job."
}
variable "benefits_bucket" { type = string }
variable "data_go_secret_name" { type = string, default = "DATA_GO_KR_SERVICE_KEY" }
variable "pseudonym_secret_name" { type = string, default = "PSEUDONYMIZATION_KEY" }
variable "mcp_token_secret_name" { type = string, default = "MCP_INTERNAL_TOKEN" }
variable "adk_token_secret_name" { type = string, default = "ADK_INTERNAL_TOKEN" }
variable "google_maps_secret_name" { type = string, default = "GOOGLE_MAPS_API_KEY" }
variable "gateway_invoker_member" {
  type        = string
  description = "Exact API Gateway backend service account principal, for example serviceAccount:service-PROJECT_NUMBER@gcp-sa-apigateway.iam.gserviceaccount.com."
}
variable "model_armor_template" { type = string, default = "couponcok-production-guardrail" }
variable "scheduler_cron" { type = string, default = "15 3 * * *" }
variable "scheduler_time_zone" { type = string, default = "Asia/Seoul" }

# CouponCock least-privilege infrastructure

This Terraform directory deliberately manages access boundaries separately from application code.

## What it creates

- One runtime service account per API, ADK, MCP, and daily store-sync job.
- A **private** mobile API invoker binding for the exact API Gateway service identity only.
- API → ADK and ADK → MCP invoker bindings, rather than project-wide `run.invoker`.
- Per-secret Secret Manager access, a read-only benefit bucket, and service-specific AI roles.
- A daily Cloud Scheduler → Cloud Run Job route that refreshes the Suwon supported-franchise directory in Firestore.

## Before `apply`

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace `PROJECT_NUMBER` and `IMMUTABLE_TAG`.
2. Run `../bootstrap-model-armor.sh <PROJECT_ID>` once and keep the returned template id.
3. Confirm the custom scheduler role contains only `run.jobs.run` in your organization policy.
4. Run `terraform init`, `terraform plan`, then have a second reviewer approve `terraform apply`.

This repository does **not** run `terraform apply` or deploy Cloud Run automatically.

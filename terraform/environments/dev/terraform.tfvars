# =============================================================================
# Terraform Variables - Dev Environment
# =============================================================================
# Configuration values for the dev environment.
# These can be overridden via CLI: terraform plan -var="environment=staging"
# =============================================================================

project_name       = "xperts"
environment        = "dev"
region             = "ca-central-1"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ca-central-1a", "ca-central-1b"]

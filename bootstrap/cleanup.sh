#!/usr/bin/env bash
# =============================================================================
# Platform Cleanup Script
# =============================================================================
# Tears down all resources created by hydrate.sh and Terraform.
# Run this to completely remove the platform.
#
# WARNING: This is destructive and irreversible!
#
# WHAT THIS DOES:
# ---------------
#   1. Runs terraform destroy (removes all AWS infrastructure)
#   1b. Validates infrastructure is destroyed
#   1c. Cleans up orphaned resources (Launch Templates, EKS addons, etc.)
#   2. Deletes S3 bucket (Terraform state)
#   3. Deletes DynamoDB table (state locking)
#   4. Deletes IAM role for GitHub Actions
#   5. Optionally deletes GitHub OIDC provider
#   6. Deletes FortiWeb secret from Secrets Manager
#   7. Removes GitHub secrets
#
# USAGE:
#   ./bootstrap/cleanup.sh                  # Full cleanup (terraform + bootstrap)
#   ./bootstrap/cleanup.sh --bootstrap-only # Remove IAM/OIDC/secrets, keep state
#   ./bootstrap/cleanup.sh --skip-terraform # DANGER: deletes state, orphans resources
#   ./bootstrap/cleanup.sh --force          # Skip confirmations
#
# HOW IT WORKS:
#   - Terraform destroy is triggered via GitHub Actions (not locally)
#   - State is stored in S3, so local terraform commands won't work
#   - The script waits for the GitHub workflow to complete
#   - Requires: gh CLI authenticated and AWS credentials for validation
#
# =============================================================================
set -euo pipefail

# Disable AWS CLI pager (prevents opening less/more)
export AWS_PAGER=""

# Disable GitHub CLI prompts
export GH_PROMPT_DISABLED=1

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Load from .hydration-config if it exists (created by hydrate.sh)
# Otherwise fall back to environment variables or defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.hydration-config"

if [[ -f "$CONFIG_FILE" ]]; then
  echo "Loading configuration from ${CONFIG_FILE}..."
  source "$CONFIG_FILE"
else
  echo "No .hydration-config found, using defaults/environment variables"
  PROJECT_NAME="${PROJECT_NAME:-xperts}"
  ENVIRONMENT="${ENVIRONMENT:-dev}"
  AWS_REGION="${AWS_REGION:-ca-central-1}"
  GITHUB_ORG="${GITHUB_ORG:-amerintlxperts}"
  GITHUB_REPO="${GITHUB_REPO:-infrastructure-2026}"

  # Derived names
  STATE_BUCKET="${PROJECT_NAME}-terraform-state-${AWS_REGION}"
  LOCK_TABLE="${PROJECT_NAME}-terraform-locks"
  OIDC_ROLE_NAME="${PROJECT_NAME}-github-actions"

  # Get AWS account ID (needed for OIDC provider ARN)
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
fi

# Flags
SKIP_TERRAFORM=false
BOOTSTRAP_ONLY=false
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-terraform)
      SKIP_TERRAFORM=true
      shift
      ;;
    --bootstrap-only)
      # Only delete bootstrap resources, KEEP state so terraform destroy still works
      BOOTSTRAP_ONLY=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo ""
      echo "Usage: cleanup.sh [options]"
      echo "  --force           Skip confirmations"
      echo "  --bootstrap-only  Remove IAM/OIDC/secrets only, keep S3 state"
      echo "  --skip-terraform  Skip terraform destroy (DANGER: orphans resources!)"
      exit 1
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------
if [[ "$FORCE" != "true" ]]; then
  echo ""
  echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                         WARNING                                 ║${NC}"
  echo -e "${RED}║                                                                 ║${NC}"
  echo -e "${RED}║  This will PERMANENTLY DELETE all platform resources:          ║${NC}"
  echo -e "${RED}║    - EKS Cluster and all workloads                             ║${NC}"
  echo -e "${RED}║    - FortiWeb instance                                         ║${NC}"
  echo -e "${RED}║    - VPC and networking                                        ║${NC}"
  echo -e "${RED}║    - Terraform state (S3 bucket)                               ║${NC}"
  echo -e "${RED}║    - All data will be LOST                                     ║${NC}"
  echo -e "${RED}║                                                                 ║${NC}"
  echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  read -p "Type 'destroy' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "destroy" ]]; then
    log_error "Aborted."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Preflight Checks
# -----------------------------------------------------------------------------
log_info "Running preflight checks..."

if ! command -v aws &> /dev/null; then
  log_error "AWS CLI is required but not installed."
  exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
  log_error "AWS credentials not configured."
  exit 1
fi

# Get AWS account ID if not loaded from config
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi
log_info "AWS Account: ${AWS_ACCOUNT_ID}"

# -----------------------------------------------------------------------------
# Step 1: Terraform Destroy (via GitHub Actions)
# -----------------------------------------------------------------------------
if [[ "$BOOTSTRAP_ONLY" == "true" ]]; then
  log_info "Step 1: Skipping terraform destroy (--bootstrap-only mode)"
  log_info "        State will be preserved so you can run 'terraform destroy' later"
elif [[ "$SKIP_TERRAFORM" == "true" ]]; then
  log_warn "Step 1: Skipping terraform destroy (--skip-terraform flag)"
  echo ""
  echo -e "${RED}WARNING: Skipping terraform destroy will orphan resources!${NC}"
  echo -e "${RED}         You will need to manually delete AWS resources.${NC}"
  echo ""
  if [[ "$FORCE" != "true" ]]; then
    read -p "Are you sure? [y/N]: " CONFIRM_SKIP
    if [[ "${CONFIRM_SKIP,,}" != "y" ]]; then
      log_error "Aborted. Run without --skip-terraform to destroy properly."
      exit 1
    fi
  fi
else
  log_info "Step 1: Terraform Destroy via GitHub Actions..."

  # Verify GitHub CLI is available
  if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) is required to trigger the destroy workflow."
    log_error "Install it or run with --skip-terraform and destroy manually."
    exit 1
  fi

  if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI not authenticated. Run 'gh auth login'"
    exit 1
  fi

  CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

  # Check if infrastructure even exists (EKS, FortiWeb, or VPC)
  INFRA_EXISTS=false
  if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
    INFRA_EXISTS=true
  fi
  FORTIWEB_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-fortiweb" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${AWS_REGION}" 2>/dev/null || true)
  if [[ -n "$FORTIWEB_INSTANCE" && "$FORTIWEB_INSTANCE" != "None" ]]; then
    INFRA_EXISTS=true
  fi
  # Check if VPC exists (tagged with project name)
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}" \
    --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}" 2>/dev/null || true)
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    INFRA_EXISTS=true
  fi

  if [[ "$INFRA_EXISTS" == "false" ]]; then
    log_info "No infrastructure found (EKS, FortiWeb, and VPC don't exist)"
    log_info "Skipping Terraform destroy - nothing to destroy"
  else
    # -------------------------------------------------------------------------
    # Pre-destroy: Clean up Route53 records created by external-dns
    # -------------------------------------------------------------------------
    # Terraform can't delete a hosted zone with non-NS/SOA records.
    # external-dns creates records that Terraform doesn't manage, so we
    # must delete them before terraform destroy.
    # -------------------------------------------------------------------------
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
      log_info "Cleaning up Route53 records created by external-dns..."
      ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN_NAME}" \
        --query "HostedZones[?Name=='${DOMAIN_NAME}.'].Id" --output text 2>/dev/null | head -1 | sed 's|/hostedzone/||')

      if [[ -n "$ZONE_ID" && "$ZONE_ID" != "None" ]]; then
        log_info "Found hosted zone: ${ZONE_ID}"
        # Get all records and filter with jq (avoids shell escaping issues with !=)
        ALL_RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --output json 2>/dev/null || echo '{"ResourceRecordSets":[]}')
        RECORDS=$(echo "$ALL_RECORDS" | jq '[.ResourceRecordSets[] | select(.Type | IN("NS", "SOA") | not)]')

        RECORD_COUNT=$(echo "$RECORDS" | jq 'length')
        if [[ "$RECORD_COUNT" -gt 0 ]]; then
          log_info "Deleting ${RECORD_COUNT} DNS records..."
          # Show what we're deleting
          echo "$RECORDS" | jq -r '.[].Name' | while read -r name; do
            log_info "  Deleting: ${name}"
          done
          # Batch all deletions into a single change for efficiency and atomic wait
          CHANGE_BATCH=$(echo "$RECORDS" | jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}')
          CHANGE_RESPONSE=$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$CHANGE_BATCH" 2>&1) || {
            log_warn "Failed to delete some records: $CHANGE_RESPONSE"
          }
          # Extract change ID and wait for propagation
          CHANGE_ID=$(echo "$CHANGE_RESPONSE" | jq -r '.ChangeInfo.Id' 2>/dev/null | sed 's|/change/||')
          if [[ -n "$CHANGE_ID" && "$CHANGE_ID" != "null" ]]; then
            log_info "Waiting for Route53 changes to propagate (Change ID: ${CHANGE_ID})..."
            aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null || log_warn "Wait timed out, continuing anyway"
          fi
          log_info "Route53 cleanup complete"
        else
          log_info "No external-dns records to clean up"
        fi
      else
        log_info "No hosted zone found for ${DOMAIN_NAME}, skipping Route53 cleanup"
      fi
    fi

    # Check if a destroy workflow is already in progress
    IN_PROGRESS_RUN=$(gh run list --workflow=terraform-destroy.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
      --status in_progress --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)

    QUEUED_RUN=$(gh run list --workflow=terraform-destroy.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
      --status queued --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)

    if [[ -n "$IN_PROGRESS_RUN" ]]; then
      log_info "Destroy workflow already in progress (Run ID: ${IN_PROGRESS_RUN})"
      log_info "Watching existing workflow instead of starting a new one..."
      RUN_ID="$IN_PROGRESS_RUN"
    elif [[ -n "$QUEUED_RUN" ]]; then
      log_info "Destroy workflow already queued (Run ID: ${QUEUED_RUN})"
      log_info "Watching existing workflow instead of starting a new one..."
      RUN_ID="$QUEUED_RUN"
    else
      # Always trigger a new destroy workflow when infrastructure exists
      # (We already checked INFRA_EXISTS earlier, so if we're here, there's something to destroy)
      log_info "Triggering terraform-destroy.yml workflow..."
      gh workflow run terraform-destroy.yml \
        --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
        -f environment="${ENVIRONMENT}" \
        -f confirm="destroy"

      # Wait for workflow to start
      sleep 5

      # Get the run ID of the workflow we just triggered
      RUN_ID=$(gh run list --workflow=terraform-destroy.yml --repo "${GITHUB_ORG}/${GITHUB_REPO}" --limit=1 --json databaseId --jq '.[0].databaseId')

      if [[ -z "$RUN_ID" ]]; then
        log_error "Failed to get workflow run ID"
        exit 1
      fi
    fi

    # Watch the workflow if we have a run ID
    if [[ -n "${RUN_ID:-}" ]]; then
      log_info "Workflow Run ID: ${RUN_ID}"
      log_info "Waiting for Terraform Destroy to complete (this may take 10-20 minutes)..."
      log_info "Press Ctrl+C to stop watching (workflow will continue in background)"

      # Use a trap to detect Ctrl+C (SIGINT)
      # gh run watch returns exit code 1 for BOTH workflow failure AND Ctrl+C
      # so we need to track whether the user interrupted
      USER_INTERRUPTED=false
      trap 'USER_INTERRUPTED=true' INT

      # Wait for the workflow to complete
      set +e
      gh run watch "${RUN_ID}" --repo "${GITHUB_ORG}/${GITHUB_REPO}" --exit-status
      WATCH_EXIT_CODE=$?
      set -e

      # Restore default INT handler
      trap - INT

      if [[ "$USER_INTERRUPTED" == "true" ]]; then
        # User pressed Ctrl+C
        echo ""
        log_warn "Stopped watching. Terraform destroy workflow continues in background."
        echo ""
        echo "To check status later:"
        echo "  gh run view ${RUN_ID} --repo ${GITHUB_ORG}/${GITHUB_REPO}"
        echo ""
        log_error "Cleanup aborted. Run cleanup again after terraform destroy completes."
        log_error "This prevents deleting secrets while infrastructure still exists."
        exit 1
      elif [[ $WATCH_EXIT_CODE -eq 0 ]]; then
        log_info "Terraform Destroy completed successfully"
      else
        # Exit code non-zero and not interrupted = workflow failed
        log_error "Terraform Destroy workflow failed!"
        log_error "Check the workflow logs: gh run view ${RUN_ID} --repo ${GITHUB_ORG}/${GITHUB_REPO} --log"
        if [[ "$FORCE" != "true" ]]; then
          exit 1
        else
          log_warn "--force specified, continuing anyway..."
        fi
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Step 1b: Validate Infrastructure is Destroyed
# -----------------------------------------------------------------------------
# Quick check that major resources are gone by querying AWS directly
if [[ "$BOOTSTRAP_ONLY" != "true" ]] && [[ "$SKIP_TERRAFORM" != "true" ]]; then
  log_info "Step 1b: Validating infrastructure is destroyed..."

  CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
  VALIDATION_FAILED=false

  # Check if EKS cluster still exists
  if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
    log_error "EKS cluster ${CLUSTER_NAME} still exists!"
    VALIDATION_FAILED=true
  else
    log_info "  ✓ EKS cluster destroyed"
  fi

  # Check if FortiWeb instance still exists
  FORTIWEB_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}-fortiweb" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text --region "${AWS_REGION}" 2>/dev/null || true)
  if [[ -n "$FORTIWEB_INSTANCE" && "$FORTIWEB_INSTANCE" != "None" ]]; then
    log_error "FortiWeb instance still exists: ${FORTIWEB_INSTANCE}"
    VALIDATION_FAILED=true
  else
    log_info "  ✓ FortiWeb instance destroyed"
  fi

  # Check if VPC still exists
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-${ENVIRONMENT}" \
    --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}" 2>/dev/null || true)
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    log_error "VPC still exists: ${VPC_ID}"
    VALIDATION_FAILED=true
  else
    log_info "  ✓ VPC destroyed"
  fi

  if [[ "$VALIDATION_FAILED" == "true" ]]; then
    log_error "Some resources were not destroyed. Check the GitHub Actions workflow logs."
    if [[ "$FORCE" != "true" ]]; then
      exit 1
    else
      log_warn "--force specified, continuing anyway..."
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Step 1c: Clean Up Orphaned AWS Resources
# -----------------------------------------------------------------------------
# Resources that may be orphaned from failed Terraform runs
log_info "Step 1c: Cleaning up orphaned AWS resources..."

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

# Delete orphaned EKS addons
for addon in coredns vpc-cni kube-proxy; do
  if aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "$addon" --region "${AWS_REGION}" 2>/dev/null; then
    log_info "Deleting orphaned EKS addon: $addon"
    aws eks delete-addon --cluster-name "${CLUSTER_NAME}" --addon-name "$addon" --region "${AWS_REGION}" 2>/dev/null || true
  fi
done

# Delete orphaned Launch Templates
LAUNCH_TEMPLATE_NAME="${CLUSTER_NAME}-eks-nodes"
if aws ec2 describe-launch-templates --launch-template-names "${LAUNCH_TEMPLATE_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  log_info "Deleting orphaned Launch Template: ${LAUNCH_TEMPLATE_NAME}"
  aws ec2 delete-launch-template --launch-template-name "${LAUNCH_TEMPLATE_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
fi

# Delete orphaned EKS Node Groups
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'nodegroups[]' --output text 2>/dev/null || true)
for ng in $NODE_GROUPS; do
  log_info "Deleting orphaned EKS Node Group: $ng"
  aws eks delete-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "$ng" --region "${AWS_REGION}" 2>/dev/null || true
  # Wait for node group deletion
  aws eks wait nodegroup-deleted --cluster-name "${CLUSTER_NAME}" --nodegroup-name "$ng" --region "${AWS_REGION}" 2>/dev/null || true
done

# Delete orphaned EKS Cluster
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  log_info "Deleting orphaned EKS Cluster: ${CLUSTER_NAME}"
  aws eks delete-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  aws eks wait cluster-deleted --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
fi

# Delete orphaned KMS aliases and keys
KMS_ALIAS="alias/${CLUSTER_NAME}-eks"
KEY_ID=$(aws kms describe-key --key-id "${KMS_ALIAS}" --region "${AWS_REGION}" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || true)
if [[ -n "$KEY_ID" && "$KEY_ID" != "None" ]]; then
  log_info "Deleting orphaned KMS alias: ${KMS_ALIAS}"
  aws kms delete-alias --alias-name "${KMS_ALIAS}" --region "${AWS_REGION}" 2>/dev/null || true
  log_info "Scheduling orphaned KMS key for deletion: ${KEY_ID}"
  aws kms schedule-key-deletion --key-id "${KEY_ID}" --pending-window-in-days 7 --region "${AWS_REGION}" 2>/dev/null || true
fi

# Delete orphaned CloudWatch Log Groups
for log_group in "/aws/eks/${CLUSTER_NAME}/cluster"; do
  if aws logs describe-log-groups --log-group-name-prefix "$log_group" --region "${AWS_REGION}" --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$log_group"; then
    log_info "Deleting orphaned CloudWatch Log Group: $log_group"
    aws logs delete-log-group --log-group-name "$log_group" --region "${AWS_REGION}" 2>/dev/null || true
  fi
done

# Delete orphaned IAM roles created by Terraform (not the GitHub Actions role)
for role_suffix in "eks-cluster" "eks-nodes" "external-secrets"; do
  ROLE_NAME="${CLUSTER_NAME}-${role_suffix}"
  if aws iam get-role --role-name "${ROLE_NAME}" 2>/dev/null; then
    log_info "Deleting orphaned IAM role: ${ROLE_NAME}"
    # Detach policies
    POLICIES=$(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
    for policy in $POLICIES; do
      aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "$policy" 2>/dev/null || true
    done
    # Delete inline policies
    INLINE=$(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames[]' --output text 2>/dev/null || true)
    for policy in $INLINE; do
      aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "$policy" 2>/dev/null || true
    done
    aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
  fi
done

# Delete orphaned OIDC providers for EKS
EKS_OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null || true)
for provider_arn in $EKS_OIDC_PROVIDERS; do
  if [[ "$provider_arn" == *"oidc.eks.${AWS_REGION}.amazonaws.com"* ]]; then
    # Check if it's for our cluster
    PROVIDER_URL=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" --query 'Url' --output text 2>/dev/null || true)
    if [[ "$PROVIDER_URL" == *"${CLUSTER_NAME}"* ]] || [[ -z "$(aws eks describe-cluster --name "${CLUSTER_NAME}" 2>/dev/null)" ]]; then
      log_info "Deleting orphaned EKS OIDC provider: $provider_arn"
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" 2>/dev/null || true
    fi
  fi
done

log_info "Orphaned resource cleanup complete"

# -----------------------------------------------------------------------------
# Step 2: Empty and Delete S3 Bucket
# -----------------------------------------------------------------------------
if [[ "$BOOTSTRAP_ONLY" == "true" ]]; then
  log_info "Step 2: Keeping S3 bucket (--bootstrap-only mode)"
else
  log_info "Step 2: Deleting S3 bucket..."

  if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
    # -------------------------------------------------------------------------
    # Validate no other projects still have state in this bucket
    # -------------------------------------------------------------------------
    # The state bucket is shared with project_bedrock. Deleting it while
    # bedrock state exists would orphan those resources permanently.
    # -------------------------------------------------------------------------
    OUR_STATE_KEY="${TF_STATE_KEY:-eks/${ENVIRONMENT}/terraform.tfstate}"
    OTHER_STATE_FILES=$(aws s3api list-objects-v2 --bucket "${STATE_BUCKET}" \
      --query "Contents[?ends_with(Key, 'terraform.tfstate') && Key != '${OUR_STATE_KEY}'].Key" \
      --output text 2>/dev/null || true)

    if [[ -n "$OTHER_STATE_FILES" && "$OTHER_STATE_FILES" != "None" ]]; then
      echo ""
      log_error "Other Terraform state files found in shared bucket!"
      log_error "These projects must be destroyed BEFORE deleting the state bucket:"
      echo ""
      for state_file in $OTHER_STATE_FILES; do
        log_error "  - s3://${STATE_BUCKET}/${state_file}"
      done
      echo ""
      log_error "Run 'terraform destroy' in those projects first, then re-run this script."
      if [[ "$FORCE" != "true" ]]; then
        exit 1
      else
        log_warn "--force specified, continuing anyway (THIS WILL ORPHAN RESOURCES!)..."
      fi
    fi

    # Delete all versions (required for versioned buckets)
    log_info "Emptying bucket ${STATE_BUCKET}..."

    # Delete all object versions
    aws s3api list-object-versions --bucket "${STATE_BUCKET}" --output json | \
      jq -r '.Versions[]? | "\(.Key)\t\(.VersionId)"' | \
      while IFS=$'\t' read -r key version; do
        aws s3api delete-object --bucket "${STATE_BUCKET}" --key "$key" --version-id "$version" 2>/dev/null || true
      done

    # Delete all delete markers
    aws s3api list-object-versions --bucket "${STATE_BUCKET}" --output json | \
      jq -r '.DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' | \
      while IFS=$'\t' read -r key version; do
        aws s3api delete-object --bucket "${STATE_BUCKET}" --key "$key" --version-id "$version" 2>/dev/null || true
      done

    # Delete the bucket
    aws s3api delete-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}"
    log_info "Deleted S3 bucket: ${STATE_BUCKET}"
  else
    log_warn "Bucket ${STATE_BUCKET} does not exist, skipping"
  fi
fi

# -----------------------------------------------------------------------------
# Step 3: Delete DynamoDB Table
# -----------------------------------------------------------------------------
if [[ "$BOOTSTRAP_ONLY" == "true" ]]; then
  log_info "Step 3: Keeping DynamoDB table (--bootstrap-only mode)"
else
  log_info "Step 3: Deleting DynamoDB table..."

  if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" 2>/dev/null; then
    aws dynamodb delete-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}"
    log_info "Deleted DynamoDB table: ${LOCK_TABLE}"
  else
    log_warn "Table ${LOCK_TABLE} does not exist, skipping"
  fi
fi

# -----------------------------------------------------------------------------
# Step 4: Delete IAM Role and Custom Policy
# -----------------------------------------------------------------------------
log_info "Step 4: Deleting IAM role and custom policy..."

# Use saved policy name from config, or derive it
POLICY_NAME="${OIDC_POLICY_NAME:-${OIDC_ROLE_NAME}-policy}"

if aws iam get-role --role-name "${OIDC_ROLE_NAME}" 2>/dev/null; then
  # Detach all policies first and track custom policies for deletion
  CUSTOM_POLICIES=()
  POLICIES=$(aws iam list-attached-role-policies --role-name "${OIDC_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text)
  for policy in $POLICIES; do
    aws iam detach-role-policy --role-name "${OIDC_ROLE_NAME}" --policy-arn "$policy"
    # Track custom policies (not AWS managed) for deletion
    if [[ "$policy" == *":policy/${OIDC_ROLE_NAME}"* ]]; then
      CUSTOM_POLICIES+=("$policy")
    fi
  done

  # Delete inline policies
  INLINE_POLICIES=$(aws iam list-role-policies --role-name "${OIDC_ROLE_NAME}" --query 'PolicyNames[]' --output text)
  for policy in $INLINE_POLICIES; do
    aws iam delete-role-policy --role-name "${OIDC_ROLE_NAME}" --policy-name "$policy"
  done

  # Delete the role
  aws iam delete-role --role-name "${OIDC_ROLE_NAME}"
  log_info "Deleted IAM role: ${OIDC_ROLE_NAME}"

  # Delete custom policies that were attached to the role
  for policy_arn in "${CUSTOM_POLICIES[@]}"; do
    aws iam delete-policy --policy-arn "$policy_arn" 2>/dev/null || true
    log_info "Deleted custom policy: $policy_arn"
  done
else
  log_warn "Role ${OIDC_ROLE_NAME} does not exist, skipping"
fi

# Also try to delete the policy directly if it exists but role was already deleted
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "${POLICY_ARN}" 2>/dev/null; then
  # Delete non-default policy versions first (required before deleting the policy)
  NON_DEFAULT_VERSIONS=$(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || true)
  for version in $NON_DEFAULT_VERSIONS; do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "$version" 2>/dev/null || true
    log_info "Deleted policy version: $version"
  done
  # Now delete the policy
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
  log_info "Deleted orphaned policy: ${POLICY_NAME}"
fi

# -----------------------------------------------------------------------------
# Step 5: Delete GitHub OIDC Provider (Optional)
# -----------------------------------------------------------------------------
log_info "Step 5: Checking GitHub OIDC provider..."

OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" 2>/dev/null; then
  if [[ "$FORCE" == "true" ]]; then
    DELETE_OIDC="y"
  else
    read -p "Delete GitHub OIDC provider? (may affect other repos) [y/N]: " DELETE_OIDC
  fi

  if [[ "${DELETE_OIDC,,}" == "y" ]]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}"
    log_info "Deleted GitHub OIDC provider"
  else
    log_warn "Keeping GitHub OIDC provider (may be used by other repos)"
  fi
else
  log_warn "GitHub OIDC provider does not exist, skipping"
fi

# -----------------------------------------------------------------------------
# Step 6: Delete Secrets from Secrets Manager
# -----------------------------------------------------------------------------
log_info "Step 6: Deleting secrets from Secrets Manager..."

# Delete FortiWeb secret
FORTIWEB_SECRET_NAME="${ENVIRONMENT}/fortiweb"
if aws secretsmanager describe-secret --secret-id "${FORTIWEB_SECRET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  if aws secretsmanager delete-secret \
    --secret-id "${FORTIWEB_SECRET_NAME}" \
    --force-delete-without-recovery \
    --region "${AWS_REGION}" 2>/dev/null; then
    log_info "Deleted secret: ${FORTIWEB_SECRET_NAME}"
  else
    log_warn "Failed to delete secret ${FORTIWEB_SECRET_NAME}, may already be scheduled for deletion"
  fi
else
  log_warn "Secret ${FORTIWEB_SECRET_NAME} does not exist, skipping"
fi

# Delete ArgoCD SSH key secret
ARGOCD_SECRET_NAME="${ENVIRONMENT}/argocd-repo-ssh"
if aws secretsmanager describe-secret --secret-id "${ARGOCD_SECRET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  if aws secretsmanager delete-secret \
    --secret-id "${ARGOCD_SECRET_NAME}" \
    --force-delete-without-recovery \
    --region "${AWS_REGION}" 2>/dev/null; then
    log_info "Deleted secret: ${ARGOCD_SECRET_NAME}"
  else
    log_warn "Failed to delete secret ${ARGOCD_SECRET_NAME}, may already be scheduled for deletion"
  fi
else
  log_warn "Secret ${ARGOCD_SECRET_NAME} does not exist, skipping"
fi

# Delete GHCR pull secret
GHCR_SECRET_NAME="${ENVIRONMENT}/ghcr-pull-secret"
if aws secretsmanager describe-secret --secret-id "${GHCR_SECRET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  if aws secretsmanager delete-secret \
    --secret-id "${GHCR_SECRET_NAME}" \
    --force-delete-without-recovery \
    --region "${AWS_REGION}" 2>/dev/null; then
    log_info "Deleted secret: ${GHCR_SECRET_NAME}"
  else
    log_warn "Failed to delete secret ${GHCR_SECRET_NAME}, may already be scheduled for deletion"
  fi
else
  log_warn "Secret ${GHCR_SECRET_NAME} does not exist, skipping"
fi

# Delete FortiWeb network config secret
FORTIWEB_NETWORK_SECRET_NAME="${ENVIRONMENT}/fortiweb-network"
if aws secretsmanager describe-secret --secret-id "${FORTIWEB_NETWORK_SECRET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  if aws secretsmanager delete-secret \
    --secret-id "${FORTIWEB_NETWORK_SECRET_NAME}" \
    --force-delete-without-recovery \
    --region "${AWS_REGION}" 2>/dev/null; then
    log_info "Deleted secret: ${FORTIWEB_NETWORK_SECRET_NAME}"
  else
    log_warn "Failed to delete secret ${FORTIWEB_NETWORK_SECRET_NAME}, may already be scheduled for deletion"
  fi
else
  log_warn "Secret ${FORTIWEB_NETWORK_SECRET_NAME} does not exist, skipping"
fi

# Delete xperts htpasswd secret
XPERTS_SECRET_NAME="${ENVIRONMENT}/xperts-htpasswd"
if aws secretsmanager describe-secret --secret-id "${XPERTS_SECRET_NAME}" --region "${AWS_REGION}" 2>/dev/null; then
  if aws secretsmanager delete-secret \
    --secret-id "${XPERTS_SECRET_NAME}" \
    --force-delete-without-recovery \
    --region "${AWS_REGION}" 2>/dev/null; then
    log_info "Deleted secret: ${XPERTS_SECRET_NAME}"
  else
    log_warn "Failed to delete secret ${XPERTS_SECRET_NAME}, may already be scheduled for deletion"
  fi
else
  log_warn "Secret ${XPERTS_SECRET_NAME} does not exist, skipping"
fi

# -----------------------------------------------------------------------------
# Step 6b: Delete ArgoCD Deploy Key from GitHub
# -----------------------------------------------------------------------------
log_info "Step 6b: Removing ArgoCD deploy key from GitHub..."

if ! command -v gh &> /dev/null; then
  log_error "GitHub CLI (gh) is required to delete deploy keys."
  log_error "Install it or manually delete the ArgoCD deploy key from GitHub."
  exit 1
fi

if ! gh auth status &>/dev/null; then
  log_error "GitHub CLI not authenticated. Run 'gh auth login'"
  exit 1
fi

# Use stored deploy key ID if available (from .hydration-config)
if [[ -n "${DEPLOY_KEY_ID:-}" ]]; then
  log_info "Using stored deploy key ID: ${DEPLOY_KEY_ID}"
  # gh deploy-key delete requires confirmation, pipe "y" to confirm
  if echo "y" | gh repo deploy-key delete "$DEPLOY_KEY_ID" --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null; then
    log_info "Deleted ArgoCD deploy key (ID: ${DEPLOY_KEY_ID})"
  else
    log_warn "Could not delete deploy key ${DEPLOY_KEY_ID} (may already be deleted)"
  fi
fi

# Also clean up any other keys named "ArgoCD" (handles duplicates)
MAX_ATTEMPTS=10
ATTEMPT=0
while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
  ARGOCD_KEY_ID=$(gh repo deploy-key list --repo "${GITHUB_ORG}/${GITHUB_REPO}" --json id,title \
    --jq '.[] | select(.title == "ArgoCD") | .id' 2>/dev/null | head -1 || true)

  if [[ -z "$ARGOCD_KEY_ID" ]]; then
    break
  fi

  # gh deploy-key delete requires confirmation, pipe "y" to confirm
  if echo "y" | gh repo deploy-key delete "$ARGOCD_KEY_ID" --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null; then
    log_info "Deleted ArgoCD deploy key (ID: ${ARGOCD_KEY_ID})"
  else
    log_warn "Failed to delete deploy key ${ARGOCD_KEY_ID}, skipping"
    break
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
  log_warn "Reached max attempts ($MAX_ATTEMPTS) cleaning up deploy keys"
fi

# Verify no ArgoCD keys remain
REMAINING_KEYS=$(gh repo deploy-key list --repo "${GITHUB_ORG}/${GITHUB_REPO}" --json id,title \
  --jq '.[] | select(.title == "ArgoCD") | .id' 2>/dev/null || true)
if [[ -n "$REMAINING_KEYS" ]]; then
  log_error "Failed to delete all ArgoCD deploy keys. Remaining: ${REMAINING_KEYS}"
  exit 1
fi

log_info "ArgoCD deploy key cleanup complete"

# -----------------------------------------------------------------------------
# Step 6c: Delete Reusable Delegation Set
# -----------------------------------------------------------------------------
# NOTE: Delegation set is intentionally NOT deleted
# It provides consistent nameservers across destroy/recreate cycles.
# Deleting it would require updating registrar nameservers on every rebuild.
# -----------------------------------------------------------------------------
if [[ -n "${DELEGATION_SET_ID:-}" ]]; then
  log_info "Step 6c: Keeping reusable delegation set (${DELEGATION_SET_ID})"
  log_info "         Nameservers remain consistent for registrar configuration"
else
  log_info "Step 6c: No delegation set configured"
fi

# -----------------------------------------------------------------------------
# Step 7: Remove GitHub Secrets
# -----------------------------------------------------------------------------
log_info "Step 7: Removing GitHub secrets..."

if command -v gh &> /dev/null && gh auth status &>/dev/null; then
  if gh repo view "${GITHUB_ORG}/${GITHUB_REPO}" &>/dev/null; then
    gh secret delete AWS_ROLE_ARN --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete AWS_REGION --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_STATE_BUCKET --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_STATE_KEY --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_LOCK_TABLE --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_VAR_admin_cidr --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_VAR_admin_role_arn --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_VAR_additional_cluster_admins --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_VAR_fortiflex_token --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_VAR_domain_name --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete TF_VAR_acme_email --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null || true
    # Keep TF_VAR_DELEGATION_SET_ID - reused across destroy/recreate cycles
    log_info "Removed GitHub secrets (kept TF_VAR_DELEGATION_SET_ID)"
  else
    log_warn "Repository ${GITHUB_ORG}/${GITHUB_REPO} not found"
  fi
else
  log_warn "GitHub CLI not available, skipping secret removal"
fi

# -----------------------------------------------------------------------------
# Step 8: Clean up local files
# -----------------------------------------------------------------------------
log_info "Step 8: Cleaning up local files..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform/environments/${ENVIRONMENT}"

if [[ -f "${TERRAFORM_DIR}/backend.tf" ]]; then
  rm -f "${TERRAFORM_DIR}/backend.tf"
  log_info "Removed backend.tf"
fi

if [[ -d "${TERRAFORM_DIR}/.terraform" ]]; then
  rm -rf "${TERRAFORM_DIR}/.terraform"
  log_info "Removed .terraform directory"
fi

rm -f "${TERRAFORM_DIR}/terraform.tfstate" "${TERRAFORM_DIR}/terraform.tfstate.backup" "${TERRAFORM_DIR}/tfplan" 2>/dev/null || true

# Remove hydration config
if [[ -f "${SCRIPT_DIR}/.hydration-config" ]]; then
  rm -f "${SCRIPT_DIR}/.hydration-config"
  log_info "Removed .hydration-config"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
log_info "=========================================="
log_info "Cleanup complete!"
log_info "=========================================="
echo ""
echo "Deleted resources:"
echo "  - Terraform infrastructure (if not skipped)"
echo "  - Orphaned AWS resources (Launch Templates, EKS addons, IAM roles)"
echo "  - S3 Bucket: ${STATE_BUCKET}"
echo "  - DynamoDB Table: ${LOCK_TABLE}"
echo "  - IAM Role: ${OIDC_ROLE_NAME}"
echo "  - IAM Policy: ${POLICY_NAME}"
echo "  - KMS Key: alias/${PROJECT_NAME}-${ENVIRONMENT}-eks (if orphaned)"
echo "  - FortiWeb Secret: ${ENVIRONMENT}/fortiweb"
echo "  - ArgoCD SSH Key Secret: ${ENVIRONMENT}/argocd-repo-ssh"
echo "  - ArgoCD Deploy Key: GitHub repository"
echo "  - Delegation Set: ${DELEGATION_SET_ID:-none}"
echo "  - GitHub Secrets"
echo "  - Local state files"
echo ""

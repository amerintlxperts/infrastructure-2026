#!/bin/bash

# Configuration
# Landing pages use region-specific DOCS_URL variables
# Content apps (ai, secops, enterprise-protection) have dual workflows
# that hardcode regional URLs

# Regional URLs
DOCS_URL_CANADA="https://canada.amerintlxperts.com"
DOCS_URL_LATAM="https://latam.amerintlxperts.com"

# Repos that need PAT secret only (no DOCS_URL)
CONTENT_REPOS=(
  "amerintlxperts/ai-2026"
  "amerintlxperts/secops-2026"
  "amerintlxperts/enterprise-protection-2026"
)

# Landing page repos (need regional DOCS_URL variables + PAT)
LANDING_REPO_CANADA="amerintlxperts/landing-page-2026-canada"
LANDING_REPO_LATAM="amerintlxperts/landing-page-2026-latam"

echo "=== Repository Setup Script ==="
echo ""
echo "This script will configure the following repos:"
echo ""
echo "Landing Pages (regional DOCS_URL + PAT):"
echo "  - $LANDING_REPO_CANADA → DOCS_URL_CANADA=$DOCS_URL_CANADA"
echo "  - $LANDING_REPO_LATAM → DOCS_URL_LATAM=$DOCS_URL_LATAM"
echo ""
echo "Content Apps (PAT only - dual regional workflows):"
for repo in "${CONTENT_REPOS[@]}"; do
  echo "  - $repo"
done
echo ""

# Prompt for PAT
read -sp "Enter PAT (with repo scope): " PAT
echo ""

if [ -z "$PAT" ]; then
  echo "Error: PAT cannot be empty"
  exit 1
fi

echo ""
echo "Applying settings..."
echo ""

# Configure Canada landing page repo
echo "→ Configuring $LANDING_REPO_CANADA..."

gh variable set DOCS_URL_CANADA --body "$DOCS_URL_CANADA" --repo "$LANDING_REPO_CANADA" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "  ✓ DOCS_URL_CANADA variable set to $DOCS_URL_CANADA"
else
  echo "  ✗ Failed to set DOCS_URL_CANADA variable"
fi

echo "$PAT" | gh secret set PAT --repo "$LANDING_REPO_CANADA" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "  ✓ PAT secret set"
else
  echo "  ✗ Failed to set PAT secret"
fi
echo ""

# Configure LATAM landing page repo
echo "→ Configuring $LANDING_REPO_LATAM..."

gh variable set DOCS_URL_LATAM --body "$DOCS_URL_LATAM" --repo "$LANDING_REPO_LATAM" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "  ✓ DOCS_URL_LATAM variable set to $DOCS_URL_LATAM"
else
  echo "  ✗ Failed to set DOCS_URL_LATAM variable"
fi

echo "$PAT" | gh secret set PAT --repo "$LANDING_REPO_LATAM" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "  ✓ PAT secret set"
else
  echo "  ✗ Failed to set PAT secret"
fi
echo ""

# Configure content app repos (PAT only)
for repo in "${CONTENT_REPOS[@]}"; do
  echo "→ Configuring $repo..."

  # Set PAT secret
  echo "$PAT" | gh secret set PAT --repo "$repo" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "  ✓ PAT secret set"
  else
    echo "  ✗ Failed to set PAT secret"
  fi

  echo ""
done

echo "=== Setup Complete ==="

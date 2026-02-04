# =============================================================================
# Route53 DNS Configuration
# =============================================================================
# Creates a hosted zone for the domain and root A record pointing to FortiWeb.
# External-DNS controller will create additional records from Ingress annotations.
#
# NAMESERVER CONSISTENCY:
# -----------------------
#   By default, Route53 assigns random nameservers each time a hosted zone is
#   created. This breaks DNS when you destroy/recreate because your registrar
#   still points to the old nameservers.
#
#   To solve this, use a reusable delegation set:
#     1. Run: ./bootstrap/hydrate.sh --set-delegation-set
#     2. Update your registrar with the nameservers shown (one-time)
#     3. Nameservers never change, even after terraform destroy/apply
#
# SETUP REQUIRED:
# ---------------
#   After terraform apply, update your domain registrar's nameservers to:
#   terraform output route53_name_servers
#
#   DNS propagation can take 24-48 hours.
#
# =============================================================================

# -----------------------------------------------------------------------------
# Route53 Hosted Zone
# -----------------------------------------------------------------------------
# Uses reusable delegation set if provided (consistent nameservers across
# destroy/recreate cycles), otherwise Route53 assigns random nameservers.
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "main" {
  name              = var.domain_name
  comment           = "Managed by Terraform - ${var.project_name} ${var.environment}"
  delegation_set_id = var.delegation_set_id != "" ? var.delegation_set_id : null

  # Force delete all records when destroying the zone
  # Without this, external-dns records block zone deletion
  force_destroy = true

  tags = {
    Name        = "${local.cluster_name}-zone"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# Root Domain A Record
# -----------------------------------------------------------------------------
# Points the root domain (e.g., amerintlxperts.com) to FortiWeb's public IP.
# Subdomains are managed by External-DNS from Ingress annotations.
# -----------------------------------------------------------------------------

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.fortiweb.public_ip]
}

# -----------------------------------------------------------------------------
# WWW Subdomain (optional convenience)
# -----------------------------------------------------------------------------
# Points www.domain.com to the same place as the root domain.
# -----------------------------------------------------------------------------

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.fortiweb.public_ip]
}

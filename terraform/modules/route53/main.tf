resource "aws_route53_zone" "local" {
  name = "${var.project_name}.local"

  tags = { Project = var.project_name }
}

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.local.zone_id
  name    = "app.${var.project_name}.local"
  type    = "A"
  ttl     = 60
  records = ["127.0.0.1"]
}

resource "aws_route53_record" "argocd" {
  zone_id = aws_route53_zone.local.zone_id
  name    = "argocd.${var.project_name}.local"
  type    = "A"
  ttl     = 60
  records = ["127.0.0.1"]
}

resource "aws_route53_record" "grafana" {
  zone_id = aws_route53_zone.local.zone_id
  name    = "grafana.${var.project_name}.local"
  type    = "A"
  ttl     = 60
  records = ["127.0.0.1"]
}

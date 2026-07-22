# ---------------------------------------------------------------------------
# ECR repositories for the two container-image Lambdas (presence, notifications).
#
# Why container images, and why two repos: both Lambdas need the native ed25519
# gem, whose C extension must be built against the Lambda runtime ABI. Shipping
# each as its own image lets that native build happen in a controlled base image
# instead of a plain zip. Two separate repositories (not one shared repo with two
# tags) were chosen so each Lambda's images version and roll independently and so
# a push to one never touches the other's tag history; the small extra of a
# second repo is worth the clean blast-radius boundary.
#
# Terraform provisions the empty repos here; the images themselves are built and
# pushed by a separate build step (a sibling agent owns the container build). The
# Lambda resources consume var.presence_image_uri / var.notifications_image_uri,
# which the deployer sets to <repo_url>:<tag> AFTER pushing (see variables.tf and
# README). Terraform never invents a digest.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "presence" {
  name                 = "cf-presence"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "notifications" {
  name                 = "cf-notifications"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep the repos from accumulating untagged layers from repeated pushes. Bounds
# storage without touching tagged, in-use images.
resource "aws_ecr_lifecycle_policy" "presence" {
  repository = aws_ecr_repository.presence.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "notifications" {
  repository = aws_ecr_repository.notifications.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

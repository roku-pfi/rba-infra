# Private image registry (ADR-0031). Tags are immutable so a deployed tag always
# names the same image; CI tags by git SHA.

resource "aws_ecr_repository" "app" {
  for_each             = toset(var.image_repositories)
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep the registry small: the last 15 images per repo.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 15 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}

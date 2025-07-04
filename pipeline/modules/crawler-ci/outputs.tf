output "codebuild_project_name" {
  description = "Name of the CodeBuild project that runs the crawler"
  value       = aws_codebuild_project.crawler_run.name
}

output "codebuild_role_name" {
  description = "Name of the IAM role used by CodeBuild"
  value       = aws_iam_role.cb_role.name
}

output "codebuild_project_name" {
  description = "Name of the CodeBuild project that runs the crawler"
  value       = aws_codebuild_project.crawler_run.name
}

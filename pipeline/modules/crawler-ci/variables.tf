variable "repo_name" {
  description = "Name of the CodeCommit repository that contains the crawler code"
  type        = string
}

variable "branch" {
  description = "Branch that CodeBuild should check out"
  type        = string
  default     = "main"
}

variable "codebuild_project" {
  description = "Logical name for the CodeBuild project"
  type        = string
  default     = "crawler-runner"
}

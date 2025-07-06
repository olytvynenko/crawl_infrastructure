###############################################################################
# Additions to Step Functions State Machine for Exit Code Monitor
###############################################################################

# This file contains the additions needed to integrate exit code monitor
# build and deployment into the existing state machine.

# Add these states to the state machine definition in main.tf:

locals {
  exit_code_monitor_states = {
    # Check if exit code monitor build should be skipped
    CheckExitCodeMonitorBuild = {
      Type = "Choice",
      Choices = [
        {
          Variable      = "$.stages.exit_code_monitor_build",
          BooleanEquals = false,
          Next          = "CheckClusterCreate"
        }
      ],
      Default = "ExitCodeMonitorBuild"
    },

    # Build exit code monitor Docker image
    ExitCodeMonitorBuild = {
      Type     = "Task",
      Resource = "arn:aws:states:::codebuild:startBuild.sync",
      Parameters = {
        ProjectName = var.exit_code_monitor_build_project
      },
      ResultPath = "$.exit_code_monitor_build_result",
      Retry = [
        {
          ErrorEquals = ["States.TaskFailed"],
          IntervalSeconds = 30,
          MaxAttempts     = 2,
          BackoffRate     = 2.0
        }
      ],
      Catch = [
        {
          ErrorEquals = ["States.ALL"],
          ResultPath = "$.exit_code_monitor_build_error",
          Next = "CheckClusterCreate"  # Continue even if monitor build fails
        }
      ],
      Next = "CheckClusterCreate"
    },

    # Deploy exit code monitor after cluster creation
    DeployExitCodeMonitor = {
      Type = "Task",
      Resource = aws_lambda_function.deploy_exit_code_monitor.arn,
      Parameters = {
        clusters = ["nv", "nc", "ohio", "oregon"]
      },
      ResultPath = "$.exit_code_monitor_deploy_result",
      Retry = [
        {
          ErrorEquals = ["States.TaskFailed"],
          IntervalSeconds = 30,
          MaxAttempts     = 2,
          BackoffRate     = 2.0
        }
      ],
      Catch = [
        {
          ErrorEquals = ["States.ALL"],
          ResultPath = "$.exit_code_monitor_deploy_error",
          Next = "CheckCrawlerBuild"  # Continue even if deployment fails
        }
      ],
      Next = "CheckCrawlerBuild"
    }
  }
}

# Instructions for integrating into main.tf:
#
# 1. In the state machine definition, change:
#    - CheckCrawlerArmBuild's Default from "CrawlerArmBuild" to "CheckExitCodeMonitorBuild"
#    - CrawlerArmBuild's Next from "CheckClusterCreate" to "CheckExitCodeMonitorBuild"
#
# 2. After NotifyClusterCreateSuccess, instead of going to "CheckCrawlerBuild",
#    go to "DeployExitCodeMonitor"
#
# 3. Add the new states from exit_code_monitor_states to the States object
#
# 4. Update the cb_project_arns to include:
#    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.exit_code_monitor_build_project}"
#
# 5. Add to the step function execution role policy:
#    - Lambda invoke permissions for deploy_exit_code_monitor
#    - CodeBuild permissions for exit_code_monitor_build_project

# Example of how the flow changes:
# 
# Original flow:
# CrawlerArmBuild -> CheckClusterCreate -> ClusterCreate -> NotifyClusterCreateSuccess -> CheckCrawlerBuild
#
# New flow:
# CrawlerArmBuild -> CheckExitCodeMonitorBuild -> ExitCodeMonitorBuild -> CheckClusterCreate -> 
# ClusterCreate -> NotifyClusterCreateSuccess -> DeployExitCodeMonitor -> CheckCrawlerBuild

# To make exit code monitor build optional, add to input:
# {
#   "stages": {
#     "exit_code_monitor_build": true,  // or false to skip
#     ...
#   }
# }
"""
Karpenter and Kubernetes cleanup: access entry conflicts, jobs, NodePools, orphaned tags.
"""
from __future__ import annotations

import logging
import subprocess
from typing import TYPE_CHECKING

import boto3

if TYPE_CHECKING:
    from .terraform_runner import TerraformRunner

logger = logging.getLogger(__name__)


def handle_access_entry_conflict(runner: "TerraformRunner") -> bool:
    """
    Handle EKS access entry conflicts by importing or deleting existing resources.
    Returns True if conflict was resolved, False otherwise.
    """
    try:
        ws = runner.workspace_current()
        cluster_config = runner.get_cluster_config(ws)
        cluster_name = cluster_config["name"]
        region = cluster_config.get("region", "us-east-1")

        eks_client = boto3.client("eks", region_name=region)
        response = eks_client.list_access_entries(clusterName=cluster_name)

        for entry_arn in response.get("accessEntries", []):
            if "eks-node-group" in entry_arn:
                logger.info("Found existing access entry: %s", entry_arn)
                resource_address = "module.karpenter.module.karpenter.aws_eks_access_entry.node[0]"
                import_id = f"{cluster_name}#{entry_arn}"
                try:
                    logger.info("Attempting to import: %s with ID: %s", resource_address, import_id)
                    runner.run("import", resource_address, import_id)
                    logger.info("Successfully imported existing access entry")
                    return True
                except Exception as e:
                    logger.warning("Failed to import access entry: %s", e)
                    try:
                        logger.info("Attempting to delete conflicting access entry")
                        eks_client.delete_access_entry(
                            clusterName=cluster_name,
                            principalArn=entry_arn,
                        )
                        logger.info("Successfully deleted conflicting access entry")
                        return True
                    except Exception as e2:
                        logger.error("Failed to delete access entry: %s", e2)
        return False
    except Exception as e:
        logger.error("Error handling access entry conflict: %s", e)
        return False


def cleanup_crawl_jobs() -> None:
    """Delete existing jobs and related pods/NodeClaims to prevent Karpenter conflicts."""
    try:
        logger.info("Checking for existing jobs...")
        delete_job_cmd = [
            "kubectl", "delete", "jobs", "--all", "--all-namespaces",
            "--ignore-not-found=true",
        ]
        result = subprocess.run(delete_job_cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0 and result.stdout.strip():
            job_count = len([l for l in result.stdout.strip().split("\n") if "deleted" in l])
            if job_count > 0:
                logger.info("Deleted %d jobs", job_count)
        elif result.returncode != 0:
            logger.warning("Failed to delete jobs: %s", result.stderr)

        delete_pods_cmd = [
            "kubectl", "delete", "pods", "--all-namespaces",
            "--field-selector", "status.phase!=Running",
            "--ignore-not-found=true",
        ]
        result = subprocess.run(delete_pods_cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0 and result.stdout.strip():
            pod_count = len([l for l in result.stdout.strip().split("\n") if "deleted" in l])
            if pod_count > 0:
                logger.info("Deleted %d crawl pods", pod_count)
        elif result.returncode != 0:
            logger.warning("Failed to delete pods: %s", result.stderr)

        delete_nodeclaims_cmd = [
            "kubectl", "delete", "nodeclaims", "--all", "--ignore-not-found=true",
        ]
        result = subprocess.run(delete_nodeclaims_cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0 and "deleted" in result.stdout:
            nodeclaim_count = len([l for l in result.stdout.strip().split("\n") if "deleted" in l])
            if nodeclaim_count > 0:
                logger.info("Deleted %d stuck NodeClaims", nodeclaim_count)
        elif result.returncode != 0:
            logger.warning("Failed to delete nodeclaims: %s", result.stderr)
    except subprocess.TimeoutExpired as e:
        logger.warning("Kubectl command timed out during cleanup: %s", e)
    except FileNotFoundError:
        logger.warning("kubectl not found - skipping crawl job cleanup")
    except Exception as e:
        logger.warning("Error during crawl job cleanup: %s", e)


def cleanup_karpenter_from_cluster(runner: "TerraformRunner") -> None:
    """Remove Karpenter resources from the cluster and from Terraform state."""
    try:
        logger.info("Cleaning up Karpenter resources from cluster...")
        kubectl_cmds = [
            ["kubectl", "delete", "nodepool", "--all", "--ignore-not-found=true", "--timeout=60s"],
            ["kubectl", "delete", "ec2nodeclass", "--all", "--ignore-not-found=true", "--timeout=60s"],
            ["kubectl", "delete", "deployment", "karpenter", "-n", "karpenter", "--ignore-not-found=true"],
            ["kubectl", "delete", "service", "-n", "karpenter", "--all", "--ignore-not-found=true"],
            ["kubectl", "delete", "configmap", "-n", "karpenter", "--all", "--ignore-not-found=true"],
            ["kubectl", "delete", "secret", "-n", "karpenter", "--all", "--ignore-not-found=true"],
            ["kubectl", "delete", "serviceaccount", "-n", "karpenter", "--all", "--ignore-not-found=true"],
            ["kubectl", "delete", "role", "-n", "karpenter", "--all", "--ignore-not-found=true"],
            ["kubectl", "delete", "rolebinding", "-n", "karpenter", "--all", "--ignore-not-found=true"],
            ["kubectl", "delete", "clusterrole", "-l", "app.kubernetes.io/name=karpenter", "--ignore-not-found=true"],
            ["kubectl", "delete", "clusterrolebinding", "-l", "app.kubernetes.io/name=karpenter", "--ignore-not-found=true"],
            ["kubectl", "delete", "webhook", "-l", "app.kubernetes.io/name=karpenter", "--ignore-not-found=true"],
            ["kubectl", "delete", "namespace", "karpenter", "--ignore-not-found=true", "--timeout=60s"],
        ]
        for cmd in kubectl_cmds:
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=70)
                if result.returncode == 0 and result.stdout.strip():
                    logger.info("Deleted: %s", result.stdout.strip())
            except subprocess.TimeoutExpired:
                logger.warning("Timeout running: %s", " ".join(cmd))
            except Exception as e:
                logger.debug("Error running %s: %s", cmd[2], e)

        try:
            runner.run("state", "rm", "module.karpenter")
            logger.info("Removed Karpenter module from Terraform state")
        except Exception as e:
            logger.debug("Could not remove Karpenter from state: %s", e)
    except Exception as e:
        logger.warning("Error during Karpenter cleanup: %s", e)


def cleanup_orphaned_karpenter_resources(cluster_name: str, region: str) -> None:
    """Remove Karpenter discovery tags from security groups/subnets in other VPCs."""
    try:
        ec2 = boto3.client("ec2", region_name=region)
        eks = boto3.client("eks", region_name=region)
        cluster_info = eks.describe_cluster(name=cluster_name)
        current_vpc_id = cluster_info["cluster"]["resourcesVpcConfig"]["vpcId"]
        logger.info("Current cluster VPC: %s", current_vpc_id)

        karpenter_tag = "karpenter.sh/discovery"
        sg_response = ec2.describe_security_groups(
            Filters=[{"Name": f"tag:{karpenter_tag}", "Values": [cluster_name]}]
        )
        for sg in sg_response["SecurityGroups"]:
            if sg["VpcId"] != current_vpc_id:
                logger.info(
                    "Removing Karpenter tag from security group %s in VPC %s",
                    sg["GroupId"], sg["VpcId"],
                )
                try:
                    ec2.delete_tags(
                        Resources=[sg["GroupId"]],
                        Tags=[{"Key": karpenter_tag, "Value": cluster_name}],
                    )
                except Exception as e:
                    logger.warning("Failed to remove tag from %s: %s", sg["GroupId"], e)

        subnet_response = ec2.describe_subnets(
            Filters=[{"Name": f"tag:{karpenter_tag}", "Values": [cluster_name]}]
        )
        for subnet in subnet_response["Subnets"]:
            if subnet["VpcId"] != current_vpc_id:
                logger.info(
                    "Removing Karpenter tag from subnet %s in VPC %s",
                    subnet["SubnetId"], subnet["VpcId"],
                )
                try:
                    ec2.delete_tags(
                        Resources=[subnet["SubnetId"]],
                        Tags=[{"Key": karpenter_tag, "Value": cluster_name}],
                    )
                except Exception as e:
                    logger.warning("Failed to remove tag from %s: %s", subnet["SubnetId"], e)
        logger.info("Completed cleanup of orphaned Karpenter resources")
    except Exception as e:
        logger.warning("Error during orphaned resource cleanup: %s", e)

#!/usr/bin/env python3
"""
cluster_manager.py – run Terraform inside ./crawl_infrastructure

Configuration hierarchy
-----------------------
1. Environment variables
   * ACTION    – create | plan | destroy | resize | health_check  (required)
   * LEVEL     – inst4 | inst8 | inst16            (required for resize)
   * CLUSTERS  – comma-separated list (fallback only)

2. Parameter Store
   * /crawl/clusters   (StringList "nv,nc,ohio,oregon")

The script requires a valid **terraform.tfvars.json** in crawl_infrastructure.
"""
from __future__ import annotations

import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable

import boto3

from .config import (
    ParameterValidationError,
    InstanceLevel,
    clusters_from_config,
    get_tag_keys,
    delete_orphan_enis,
)
from .terraform_runner import TerraformRunner
from .eks_health import check_cluster_status, check_cluster_health, wait_for_cluster_deletion
from .karpenter_cleanup import (
    handle_access_entry_conflict,
    cleanup_crawl_jobs,
    cleanup_karpenter_from_cluster,
    cleanup_orphaned_karpenter_resources,
)

logger = logging.getLogger(__name__)


class ClusterManager:
    """Orchestrates Terraform and AWS operations for EKS cluster lifecycle."""

    def __init__(self, working_directory: str | Path) -> None:
        self._runner = TerraformRunner(working_directory)

    def plan(self, wss: Iterable[str]) -> None:
        for ws in wss:
            self._runner.workspace_select_or_create(ws)
            self._runner.run("plan", stream_output=True)

    def create(self, wss: Iterable[str]) -> None:
        for ws in wss:
            cluster_name = None
            region = "us-east-1"
            try:
                cluster_config = self._runner.get_cluster_config(ws)
                cluster_name = cluster_config["name"]
                region = cluster_config.get("region", "us-east-1")
                status = check_cluster_status(cluster_name, region)

                if status == "ACTIVE":
                    logger.info(
                        "Cluster '%s' already exists and is ACTIVE in region %s.",
                        cluster_name, region,
                    )
                    health = check_cluster_health(cluster_name, region)
                    logger.info("Health check results:")
                    logger.info("  - Status: %s", health["status"])
                    logger.info("  - API Accessible: %s", health["api_accessible"])
                    logger.info("  - Authentication: %s", health["auth_working"])
                    logger.info(
                        "  - Node Groups: %s",
                        "Healthy" if health["node_groups_healthy"] else "Issues detected",
                    )
                    logger.info("  - Nodes Ready: %s", health["nodes_ready"])
                    logger.info(
                        "  - Core Pods: %s",
                        "Healthy" if health.get("core_pods_healthy", False) else "Issues detected or not checked",
                    )
                    if health["errors"]:
                        logger.warning("Health check issues found:")
                        for err in health["errors"]:
                            logger.warning("  - %s", err)

                    is_healthy = (
                        health["status"] == "ACTIVE"
                        and health["api_accessible"]
                        and health["auth_working"]
                        and health["node_groups_healthy"]
                    )
                    if not is_healthy:
                        logger.error("Cluster health checks failed. Will destroy and recreate the cluster.")
                        self._runner.workspace_select_or_create(ws)
                        self.destroy([ws], force=True)
                        wait_for_cluster_deletion(cluster_name, region)
                    else:
                        logger.info("Cluster is healthy - proceeding with Karpenter deployment...")
                        self._runner.workspace_select_or_create(ws)
                        logger.info("Skipping Stage 1 (cluster creation) as cluster already exists and is healthy")
                        subprocess.run(
                            [
                                "aws", "eks", "update-kubeconfig",
                                "--name", cluster_name,
                                "--region", region,
                            ],
                            capture_output=True,
                        )
                        logger.info("Cleaning up existing Karpenter installation...")
                        cleanup_karpenter_from_cluster(self._runner)
                        logger.info("Stage 2: Installing Karpenter...")
                        logger.info("Cleaning up any existing jobs...")
                        cleanup_crawl_jobs()
                        logger.info("Checking for orphaned Karpenter resources...")
                        cleanup_orphaned_karpenter_resources(cluster_name, region)
                        try:
                            self._runner.run(
                                "apply", "-auto-approve",
                                "-target", "module.karpenter",
                                stream_output=True,
                            )
                        except RuntimeError as e:
                            if "ResourceInUseException" in str(e) and "access entry" in str(e):
                                logger.warning("EKS access entry conflict detected, attempting to resolve...")
                                if handle_access_entry_conflict(self._runner):
                                    logger.info("Resolved access entry conflict, retrying apply...")
                                    self._runner.run(
                                        "apply", "-auto-approve",
                                        "-target", "module.karpenter",
                                        stream_output=True,
                                    )
                                else:
                                    raise
                            else:
                                raise
                        logger.info("Stage 3: Applying remaining resources...")
                        self._runner.run("apply", "-auto-approve", stream_output=True)
                        continue

                if status == "DELETING":
                    logger.info(
                        "Cluster '%s' is being deleted in region %s. Waiting for deletion to complete...",
                        cluster_name, region,
                    )
                    wait_for_cluster_deletion(cluster_name, region)
                elif status is not None:
                    logger.warning(
                        "Cluster '%s' exists with unexpected status: %s. Will destroy and recreate.",
                        cluster_name, status,
                    )
                    self._runner.workspace_select_or_create(ws)
                    self.destroy([ws], force=True)
                    wait_for_cluster_deletion(cluster_name, region)

            except Exception as e:
                logger.warning("Could not check cluster status for workspace '%s': %s. Proceeding with terraform apply.", ws, e)

            self._runner.workspace_select_or_create(ws)
            cluster_config = self._runner.get_cluster_config(ws)
            cluster_name = cluster_config["name"]
            region = cluster_config.get("region", "us-east-1")

            logger.info("Creating cluster for workspace '%s'...", ws)
            logger.info("Stage 1: Creating EKS cluster and node groups...")
            self._runner.run("apply", "-auto-approve", "-target", "module.cluster", stream_output=True)

            logger.info("Stage 2: Installing Karpenter...")
            logger.info("Cleaning up any existing crawl jobs...")
            cleanup_crawl_jobs()
            logger.info("Checking for orphaned Karpenter resources...")
            cleanup_orphaned_karpenter_resources(cluster_name, region)

            logger.info("Testing cluster connectivity before Karpenter installation...")
            try:
                result = subprocess.run(
                    ["aws", "eks", "get-token", "--cluster-name", cluster_name, "--region", region],
                    capture_output=True, text=True, timeout=30,
                )
                if result.returncode == 0:
                    logger.info("Successfully generated EKS token")
                else:
                    logger.error("Failed to generate EKS token: %s", result.stderr)
                result = subprocess.run(
                    ["aws", "eks", "describe-cluster", "--name", cluster_name, "--region", region, "--query", "cluster.endpoint"],
                    capture_output=True, text=True, timeout=30,
                )
                if result.returncode == 0:
                    logger.info("Cluster endpoint: %s", result.stdout.strip())
                else:
                    logger.error("Failed to describe cluster: %s", result.stderr)
            except subprocess.TimeoutExpired:
                logger.error("Timeout while testing cluster - this indicates connectivity issues")
            except Exception as e:
                logger.error("Error testing cluster connectivity: %s", e)

            try:
                self._runner.run(
                    "apply", "-auto-approve",
                    "-target", "module.karpenter",
                    stream_output=True,
                )
            except RuntimeError as e:
                if "ResourceInUseException" in str(e) and "access entry" in str(e):
                    logger.warning("EKS access entry conflict detected, attempting to resolve...")
                    if handle_access_entry_conflict(self._runner):
                        logger.info("Resolved access entry conflict, retrying apply...")
                        self._runner.run(
                            "apply", "-auto-approve",
                            "-target", "module.karpenter",
                            stream_output=True,
                        )
                    else:
                        raise
                else:
                    raise

            logger.info("Stage 3: Applying remaining resources...")
            self._runner.run("apply", "-auto-approve", stream_output=True)

    def destroy(self, wss: Iterable[str], force: bool = False) -> None:
        """
        Remove the selected workspaces.

        1. Optionally target Karpenter resources first (normal destroy).
        2. Run terraform destroy.
        If force=True, strip Kubernetes resources from state and use AWS APIs for instances/node groups.
        """
        for ws in wss:
            self._runner.workspace_select_or_create(ws)
            try:
                cluster_config = self._runner.get_cluster_config(ws)
                cluster_name = cluster_config["name"]
                region = cluster_config.get("region", "us-east-1")
            except Exception as e:
                logger.warning("Could not get cluster config: %s", e)
                cluster_name = None
                region = "us-east-1"

            if force:
                logger.info("FORCE DESTROY: Removing all Kubernetes-related resources from state")
                code, stdout, _ = self._runner.run_capture("state", "list")
                if code == 0:
                    all_resources = [r for r in stdout.strip().split("\n") if r]
                    for resource in all_resources:
                        if any(x in resource for x in ["helm_release", "kubectl_manifest", "kubernetes_"]):
                            try:
                                self._runner.run("state", "rm", resource)
                                logger.info("Removed %s from state", resource)
                            except Exception as e:
                                logger.debug("Could not remove %s: %s", resource, e)

                if cluster_name:
                    logger.info("FORCE DESTROY: Terminating all EC2 instances for cluster %s", cluster_name)
                    try:
                        ec2 = boto3.client("ec2", region_name=region)
                        instances = ec2.describe_instances(
                            Filters=[
                                {"Name": "tag:kubernetes.io/cluster/" + cluster_name, "Values": ["owned"]},
                                {"Name": "instance-state-name", "Values": ["running", "pending", "stopping", "stopped"]},
                            ]
                        )
                        instance_ids = [
                            i["InstanceId"]
                            for r in instances["Reservations"]
                            for i in r["Instances"]
                        ]
                        if instance_ids:
                            logger.info("Force terminating %d instances: %s", len(instance_ids), instance_ids)
                            ec2.terminate_instances(InstanceIds=instance_ids)
                    except Exception as e:
                        logger.warning("Could not force terminate instances: %s", e)
                    try:
                        eks = boto3.client("eks", region_name=region)
                        for ng in eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", []):
                            logger.info("Force deleting node group: %s", ng)
                            try:
                                eks.delete_nodegroup(clusterName=cluster_name, nodegroupName=ng)
                            except Exception as e:
                                logger.debug("Could not delete node group %s: %s", ng, e)
                    except Exception as e:
                        logger.debug("Could not list/delete node groups: %s", e)
            else:
                karpenter_targets = [
                    "-target", "module.karpenter.helm_release.karpenter",
                    "-target", "module.karpenter.kubectl_manifest.karpenter_nodepool",
                    "-target", "module.karpenter.kubectl_manifest.karpenter_node_class",
                ]
                try:
                    self._runner.run("destroy", "-auto-approve", *karpenter_targets, stream_output=True)
                except RuntimeError as exc:
                    logger.warning("targeted Karpenter destroy failed in workspace '%s': %s", ws, exc)

            try:
                self._runner.run("destroy", "-auto-approve", "-refresh=false", stream_output=True)
            except RuntimeError as exc:
                if force:
                    logger.warning("Terraform destroy failed, but continuing with force cleanup: %s", exc)
                else:
                    raise

            try:
                delete_orphan_enis(tag_keys=get_tag_keys())
            except Exception as exc:
                logger.warning("Orphan-ENI cleanup failed: %s", exc)

    def resize(self, wss: Iterable[str], level: InstanceLevel) -> None:
        for ws in wss:
            self._runner.workspace_select_or_create(ws)
            self._runner.update_level(level)
            self._runner.run("apply", "-auto-approve", stream_output=True)

    def health_check(self, wss: Iterable[str]) -> bool:
        """Run health checks on the given workspaces. Return True if all healthy."""
        overall_healthy = True
        for ws in wss:
            try:
                cluster_config = self._runner.get_cluster_config(ws)
                cluster_name = cluster_config["name"]
                region = cluster_config.get("region", "us-east-1")
                logger.info("\n%s", "=" * 60)
                logger.info("Health check for cluster: %s (%s)", cluster_name, region)
                logger.info("%s", "=" * 60)

                status = check_cluster_status(cluster_name, region)
                if status is None:
                    logger.error("Cluster '%s' does not exist", cluster_name)
                    overall_healthy = False
                    continue

                health = check_cluster_health(cluster_name, region)
                logger.info("Status: %s", health["status"])
                logger.info("API Server: %s", "✓ Accessible" if health["api_accessible"] else "✗ Not accessible")
                logger.info("Authentication: %s", "✓ Working" if health["auth_working"] else "✗ Failed")
                logger.info("Node Groups: %s", "✓ Healthy" if health["node_groups_healthy"] else "✗ Issues detected")
                logger.info("Nodes: %s", "✓ All Ready" if health["nodes_ready"] else "✗ Some not ready")
                logger.info("Core Pods: %s", "✓ Healthy" if health["core_pods_healthy"] else "✗ Issues detected")
                if health["errors"]:
                    logger.error("Issues found:")
                    for err in health["errors"]:
                        logger.error("  - %s", err)

                is_healthy = (
                    health["status"] == "ACTIVE"
                    and health["api_accessible"]
                    and health["auth_working"]
                    and health["node_groups_healthy"]
                )
                if is_healthy:
                    logger.info("✓ Cluster '%s' is HEALTHY", cluster_name)
                else:
                    logger.error("✗ Cluster '%s' is UNHEALTHY", cluster_name)
                    overall_healthy = False
            except Exception as e:
                logger.error("Failed to check health for workspace '%s': %s", ws, e)
                overall_healthy = False
        return overall_healthy


def main() -> None:
    logging.basicConfig(level=os.getenv("LOGLEVEL", "INFO"))
    action = (os.getenv("ACTION") or "").lower()
    if not action:
        raise ParameterValidationError("ACTION env var not set")

    clusters = clusters_from_config()
    working_dir = Path(__file__).resolve().parent
    mgr = ClusterManager(working_dir)

    if action in {"create", "apply"}:
        mgr.create(clusters)
    elif action == "plan":
        mgr.plan(clusters)
    elif action == "destroy":
        mgr.destroy(clusters)
    elif action == "resize":
        level = InstanceLevel.from_str(os.getenv("LEVEL", ""))
        mgr.resize(clusters, level)
    elif action in ("health", "health_check"):
        healthy = mgr.health_check(clusters)
        sys.exit(0 if healthy else 1)
    else:
        raise ParameterValidationError(f"unsupported ACTION '{action}'")


if __name__ == "__main__":
    try:
        main()
    except ParameterValidationError as exc:
        logging.error("%s", exc)
        sys.exit(2)
    except Exception as exc:
        logging.exception("unhandled error: %s", exc)
        sys.exit(1)

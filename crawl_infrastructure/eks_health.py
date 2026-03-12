"""
EKS cluster status, health checks, and wait-for-deletion helpers.
"""
from __future__ import annotations

import json
import logging
import subprocess
import time
from typing import Any, Dict, Optional

import boto3

logger = logging.getLogger(__name__)


def check_cluster_status(cluster_name: str, region: str) -> Optional[str]:
    """Return EKS cluster status, or None if cluster does not exist."""
    try:
        eks_client = boto3.client("eks", region_name=region)
        response = eks_client.describe_cluster(name=cluster_name)
        return response["cluster"]["status"]
    except Exception as e:
        if "ResourceNotFoundException" in str(type(e)):
            return None
        logger.error("Error checking cluster status: %s", e)
        return None


def check_cluster_health(cluster_name: str, region: str) -> Dict[str, Any]:
    """
    Run health checks on the EKS cluster.

    Returns dict with: status, api_accessible, auth_working, nodes_ready,
    node_groups_healthy, core_pods_healthy, errors (list).
    """
    health: Dict[str, Any] = {
        "status": None,
        "api_accessible": False,
        "auth_working": False,
        "nodes_ready": False,
        "node_groups_healthy": False,
        "core_pods_healthy": False,
        "errors": [],
    }

    try:
        eks_client = boto3.client("eks", region_name=region)
        cluster_info = eks_client.describe_cluster(name=cluster_name)
        health["status"] = cluster_info["cluster"]["status"]

        if health["status"] != "ACTIVE":
            health["errors"].append(f"Cluster status is {health['status']}, not ACTIVE")
            return health
    except Exception as e:
        health["errors"].append(f"Failed to describe cluster: {e}")
        return health

    # API server connectivity
    try:
        endpoint = cluster_info["cluster"]["endpoint"]
        curl_cmd = ["curl", "-k", "--connect-timeout", "5", f"{endpoint}/healthz"]
        result = subprocess.run(curl_cmd, capture_output=True, text=True)
        if result.returncode == 0 and "ok" in result.stdout:
            health["api_accessible"] = True
        else:
            health["errors"].append(f"API server not accessible: {result.stderr}")
    except Exception as e:
        health["errors"].append(f"Failed to test API connectivity: {e}")

    # Authentication
    try:
        token_cmd = [
            "aws", "eks", "get-token",
            "--cluster-name", cluster_name,
            "--region", region,
        ]
        result = subprocess.run(token_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            health["auth_working"] = True
        else:
            health["errors"].append(f"Failed to get auth token: {result.stderr}")
    except subprocess.TimeoutExpired:
        health["errors"].append("Timeout getting auth token")
    except Exception as e:
        health["errors"].append(f"Auth check failed: {e}")

    # Node groups
    try:
        nodegroups = eks_client.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])
        all_healthy = True
        for ng_name in nodegroups:
            ng_info = eks_client.describe_nodegroup(
                clusterName=cluster_name,
                nodegroupName=ng_name,
            )
            ng_health = ng_info["nodegroup"].get("health", {})
            if ng_health.get("issues"):
                all_healthy = False
                for issue in ng_health["issues"]:
                    health["errors"].append(
                        f"Node group {ng_name}: {issue.get('message', 'Unknown issue')}"
                    )
        health["node_groups_healthy"] = all_healthy
    except Exception as e:
        health["errors"].append(f"Failed to check node groups: {e}")

    # Nodes and core pods via kubectl
    try:
        update_cmd = [
            "aws", "eks", "update-kubeconfig",
            "--name", cluster_name,
            "--region", region,
            "--kubeconfig", "/tmp/health-check-kubeconfig",
        ]
        subprocess.run(update_cmd, capture_output=True, check=True)

        nodes_cmd = [
            "kubectl", "--kubeconfig", "/tmp/health-check-kubeconfig",
            "get", "nodes", "-o", "json",
        ]
        result = subprocess.run(nodes_cmd, capture_output=True, text=True)
        if result.returncode == 0:
            nodes_data = json.loads(result.stdout)
            all_ready = True
            for node in nodes_data.get("items", []):
                node_name = node["metadata"]["name"]
                conditions = node.get("status", {}).get("conditions", [])
                ready = any(
                    c["type"] == "Ready" and c["status"] == "True"
                    for c in conditions
                )
                if not ready:
                    all_ready = False
                    health["errors"].append(f"Node {node_name} is not Ready")
            health["nodes_ready"] = all_ready

            try:
                core_pods_cmd = [
                    "kubectl", "--kubeconfig", "/tmp/health-check-kubeconfig",
                    "get", "pods", "-n", "kube-system", "-o", "json",
                ]
                pods_result = subprocess.run(core_pods_cmd, capture_output=True, text=True)
                if pods_result.returncode == 0:
                    pods_data = json.loads(pods_result.stdout)
                    core_components = {"coredns": False, "aws-node": False, "kube-proxy": False}
                    for pod in pods_data.get("items", []):
                        pod_name = pod["metadata"]["name"]
                        pod_ready = all(
                            c.get("status") == "True"
                            for c in pod.get("status", {}).get("conditions", [])
                            if c.get("type") == "Ready"
                        )
                        for component in core_components:
                            if component in pod_name and pod_ready:
                                core_components[component] = True
                    health["core_pods_healthy"] = all(core_components.values())
                    for component, is_healthy in core_components.items():
                        if not is_healthy:
                            health["errors"].append(f"Core component {component} is not healthy")
            except Exception as e:
                logger.debug("Could not check core pods: %s", e)
        else:
            health["errors"].append(f"Failed to get nodes: {result.stderr}")
    except Exception as e:
        logger.debug("Skipping kubectl node check: %s", e)

    return health


def wait_for_cluster_deletion(
    cluster_name: str,
    region: str,
    max_wait: int = 600,
) -> None:
    """Wait for cluster to be deleted (default max 10 minutes)."""
    start_time = time.time()
    while time.time() - start_time < max_wait:
        status = check_cluster_status(cluster_name, region)
        if status is None:
            logger.info("Cluster '%s' has been deleted", cluster_name)
            return
        if status == "DELETING":
            logger.info("Cluster '%s' is still deleting, waiting...", cluster_name)
            time.sleep(30)
        else:
            raise RuntimeError(f"Unexpected cluster status during deletion: {status}")
    raise RuntimeError(f"Timeout waiting for cluster '{cluster_name}' deletion")

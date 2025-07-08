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
   * /crawl/clusters   (StringList “nv,nc,ohio,oregon”)

The script requires a valid **terraform.tfvars.json** in crawl_infrastructure.
"""
from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import sys
import time
from enum import Enum
from functools import lru_cache
from pathlib import Path
from typing import Iterable, List, Optional
import boto3

logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────────────────────
class ParameterValidationError(ValueError):
    """Raised on missing or invalid user input."""


class InstanceLevel(str, Enum):
    inst4 = "inst4"
    inst8 = "inst8"
    inst16 = "inst16"

    @classmethod
    def from_str(cls, value: str) -> "InstanceLevel":
        try:
            return InstanceLevel(value)
        except ValueError as exc:
            raise ParameterValidationError(
                f"LEVEL must be one of {[m.value for m in cls]} (got '{value}')"
            ) from exc


# ─────────────────────────────────────────────────────────────────────────────
# Parameter Store helper
# ─────────────────────────────────────────────────────────────────────────────
_ssm = boto3.client("ssm")


@lru_cache(maxsize=32)
def _param(name: str) -> str | None:
    """Return parameter value or None if missing."""
    for candidate in (f"/crawl/{name}", name):
        try:
            res = _ssm.get_parameter(Name=candidate, WithDecryption=True)
            return res["Parameter"]["Value"]
        except _ssm.exceptions.ParameterNotFound:
            continue
    return None


def _clusters_from_config() -> List[str]:
    """
    Resolve cluster list:

      1. try Parameter Store  (/crawl/clusters) – StringList
      2. fallback to $CLUSTERS env var
    """
    raw = _param("clusters") or os.getenv("CLUSTERS")
    if not raw:
        raise ParameterValidationError(
            "cluster list not found: set /crawl/clusters (StringList) "
            "or CLUSTERS env var"
        )
    return [c.strip() for c in raw.split(",") if c.strip()]


# ---------------------------------------------------------------------------#
# Helper utilities (kept local to avoid an extra import dependency)
# ---------------------------------------------------------------------------#
def _get_tag_keys() -> list[str]:
    """Return the list of tag keys that identify cluster resources.

    Uses the same environment variables as the Lambda checker so the two
    components stay in sync.
    """
    raw = os.getenv("TAG_KEYS", "")
    if raw:
        try:
            keys = json.loads(raw)
            if not isinstance(keys, list):
                raise ValueError
            return [k for k in keys if isinstance(k, str) and k.strip()]
        except Exception:
            logger.warning("TAG_KEYS is not a valid JSON array, ignoring")

    legacy = os.getenv("TAG_KEY")
    return [legacy] if legacy else []


def _delete_orphan_enis(tag_keys: list[str]) -> None:
    """Remove all detached ENIs that still carry one of *tag_keys*.

    Only interfaces whose `Status` is already `available` are deleted so we
    never touch resources that are genuinely in use.
    """
    if not tag_keys:
        logger.info("No tag keys provided – skipping orphan-ENI cleanup")
        return

    ec2 = boto3.client("ec2")
    filters = [
        {"Name": "status", "Values": ["available"]},
        {"Name": "tag-key", "Values": tag_keys},
    ]

    paginator = ec2.get_paginator("describe_network_interfaces")
    orphan_ids: list[str] = []

    for page in paginator.paginate(Filters=filters):
        orphan_ids.extend(
            eni["NetworkInterfaceId"] for eni in page["NetworkInterfaces"]
        )

    if not orphan_ids:
        logger.info("No orphan ENIs found")
        return

    logger.info("Deleting %d orphan ENIs: %s", len(orphan_ids), orphan_ids)
    for eni_id in orphan_ids:
        try:
            ec2.delete_network_interface(NetworkInterfaceId=eni_id)
            logger.debug("Deleted ENI %s", eni_id)
        except Exception as exc:  # broad catch – we want to keep destroying
            logger.warning("Failed to delete ENI %s: %s", eni_id, exc)



# ─────────────────────────────────────────────────────────────────────────────
# Cluster manager (unchanged core logic)
# ─────────────────────────────────────────────────────────────────────────────
class ClusterManager:
    def __init__(self, working_directory: str | Path):
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' not found")
        self._chdir = f"-chdir={self.wd}"
        logging.debug("Terraform chdir flag: %s", self._chdir)

    # ---------------- internal runners --------------------------------------
    def _run(self, *args: str, stream_output: bool = False):
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s", " ".join(cmd))
        
        if stream_output:
            # Stream output in real-time for long-running operations
            process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, 
                                     text=True, bufsize=1, universal_newlines=True)
            
            output_lines = []
            for line in process.stdout:
                print(line, end='')  # Print to stdout for real-time visibility
                output_lines.append(line)
            
            process.wait()
            output = ''.join(output_lines)
            
            if process.returncode != 0:
                # Check for state lock error
                if "Error acquiring the state lock" in output or "Error releasing the state lock" in output:
                    lock_id = self._extract_lock_id(output)
                    if lock_id:
                        logging.warning(f"State lock detected (ID: {lock_id}). Attempting to unlock...")
                        self._force_unlock(lock_id)
                        # Retry with streaming
                        logging.info("Retrying command after unlocking state...")
                        return self._run(*args, stream_output=stream_output)
                
                logging.error(f"Command failed with exit code {process.returncode}")
                # Include relevant error information in the exception
                error_msg = f"terraform {args[0]} failed (exit {process.returncode})"
                if "ResourceInUseException" in output:
                    # Include the specific error for better handling
                    error_lines = [line for line in output_lines if "Error:" in line or "ResourceInUseException" in line]
                    if error_lines:
                        error_msg += f" - {' '.join(error_lines[-5:])}"  # Last 5 error lines
                raise RuntimeError(error_msg)
        else:
            # Original behavior for quick commands
            result = subprocess.run(cmd, text=True, capture_output=True)
            
            if result.returncode != 0:
                if "Error acquiring the state lock" in result.stderr or "Error releasing the state lock" in result.stderr:
                    lock_id = self._extract_lock_id(result.stderr)
                    if lock_id:
                        logging.warning(f"State lock detected (ID: {lock_id}). Attempting to unlock...")
                        self._force_unlock(lock_id)
                        # Retry the command after unlocking
                        logging.info("Retrying command after unlocking state...")
                        result = subprocess.run(cmd, text=True, capture_output=True)
                        if result.returncode == 0:
                            logging.info("Command succeeded after unlocking state")
                            return
                
                # If still failing, raise the error
                logging.error(f"Command failed: {result.stderr}")
                raise RuntimeError(f"terraform {args[0]} failed (exit {result.returncode})")

    def _extract_lock_id(self, error_text: str) -> Optional[str]:
        """Extract lock ID from terraform error message."""
        # Try standard format first: "ID:        df4d41d1-..."
        match = re.search(r'ID:\s+([a-f0-9-]+)', error_text)
        if match:
            return match.group(1)
        
        # Try format from "Error releasing" message: 'lock ID "df4d41d1-..."'
        match = re.search(r'lock ID\s+"([a-f0-9-]+)"', error_text)
        return match.group(1) if match else None
    
    def _force_unlock(self, lock_id: str):
        """Force unlock terraform state."""
        unlock_cmd = ["terraform", self._chdir, "force-unlock", "-force", lock_id]
        logging.debug("$ %s", " ".join(unlock_cmd))
        result = subprocess.run(unlock_cmd, text=True, capture_output=True)
        if result.returncode == 0:
            logging.info(f"Successfully unlocked state (ID: {lock_id})")
        else:
            logging.error(f"Failed to unlock state: {result.stderr}")
            raise RuntimeError(f"Failed to unlock terraform state (ID: {lock_id})")

    def _workspace_select_or_create(self, ws: str):
        try:
            self._run("workspace", "select", ws)
            logging.info("Selected workspace '%s'", ws)
        except RuntimeError:
            logging.info("Workspace '%s' missing – creating", ws)
            self._run("workspace", "new", ws)

    def _get_cluster_config(self, workspace: str) -> dict:
        """Get cluster configuration from terraform.tfvars.json for the given workspace."""
        tfvars_path = self.wd / "terraform.tfvars.json"
        with open(tfvars_path) as f:
            config = json.load(f)
        
        if workspace not in config.get("clusters", {}):
            raise ParameterValidationError(f"Workspace '{workspace}' not found in terraform.tfvars.json")
        
        return config["clusters"][workspace]

    def _check_cluster_status(self, cluster_name: str, region: str) -> Optional[str]:
        """Check if EKS cluster exists and return its status."""
        try:
            eks_client = boto3.client('eks', region_name=region)
            response = eks_client.describe_cluster(name=cluster_name)
            return response['cluster']['status']
        except Exception as e:
            if 'ResourceNotFoundException' in str(type(e)):
                return None
            logging.error(f"Error checking cluster status: {e}")
            return None
    
    def _check_cluster_health(self, cluster_name: str, region: str) -> dict:
        """Perform comprehensive health checks on the EKS cluster.
        
        Returns:
            dict: Health check results with keys:
                - status: Cluster status (ACTIVE, etc.)
                - api_accessible: Whether API server is accessible
                - auth_working: Whether authentication works
                - nodes_ready: Whether nodes are in Ready state
                - node_groups_healthy: Whether node groups are healthy
                - core_pods_healthy: Whether core system pods are running
                - errors: List of error messages
        """
        health = {
            "status": None,
            "api_accessible": False,
            "auth_working": False,
            "nodes_ready": False,
            "node_groups_healthy": False,
            "core_pods_healthy": False,
            "errors": []
        }
        
        # 1. Check cluster status
        try:
            eks_client = boto3.client('eks', region_name=region)
            cluster_info = eks_client.describe_cluster(name=cluster_name)
            health["status"] = cluster_info['cluster']['status']
            
            if health["status"] != "ACTIVE":
                health["errors"].append(f"Cluster status is {health['status']}, not ACTIVE")
                return health  # No point checking further if not active
                
        except Exception as e:
            health["errors"].append(f"Failed to describe cluster: {e}")
            return health
        
        # 2. Check API server connectivity
        try:
            endpoint = cluster_info['cluster']['endpoint']
            # Test if we can reach the endpoint (using curl to avoid auth issues)
            curl_cmd = ["curl", "-k", "--connect-timeout", "5", f"{endpoint}/healthz"]
            result = subprocess.run(curl_cmd, capture_output=True, text=True)
            if result.returncode == 0 and "ok" in result.stdout:
                health["api_accessible"] = True
            else:
                health["errors"].append(f"API server not accessible: {result.stderr}")
        except Exception as e:
            health["errors"].append(f"Failed to test API connectivity: {e}")
        
        # 3. Check authentication
        try:
            token_cmd = ["aws", "eks", "get-token", "--cluster-name", cluster_name, "--region", region]
            result = subprocess.run(token_cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                health["auth_working"] = True
            else:
                health["errors"].append(f"Failed to get auth token: {result.stderr}")
        except subprocess.TimeoutExpired:
            health["errors"].append("Timeout getting auth token")
        except Exception as e:
            health["errors"].append(f"Auth check failed: {e}")
        
        # 4. Check node groups
        try:
            nodegroups = eks_client.list_nodegroups(clusterName=cluster_name).get('nodegroups', [])
            all_healthy = True
            for ng_name in nodegroups:
                ng_info = eks_client.describe_nodegroup(
                    clusterName=cluster_name,
                    nodegroupName=ng_name
                )
                ng_health = ng_info['nodegroup'].get('health', {})
                if ng_health.get('issues'):
                    all_healthy = False
                    for issue in ng_health['issues']:
                        health["errors"].append(f"Node group {ng_name}: {issue.get('message', 'Unknown issue')}")
                        
            health["node_groups_healthy"] = all_healthy
        except Exception as e:
            health["errors"].append(f"Failed to check node groups: {e}")
        
        # 5. Check nodes via kubectl (if kubeconfig is set up)
        try:
            # Update kubeconfig first
            update_cmd = ["aws", "eks", "update-kubeconfig", "--name", cluster_name, "--region", region, "--kubeconfig", "/tmp/health-check-kubeconfig"]
            subprocess.run(update_cmd, capture_output=True, check=True)
            
            # Check nodes
            nodes_cmd = ["kubectl", "--kubeconfig", "/tmp/health-check-kubeconfig", "get", "nodes", "-o", "json"]
            result = subprocess.run(nodes_cmd, capture_output=True, text=True)
            if result.returncode == 0:
                import json
                nodes_data = json.loads(result.stdout)
                all_ready = True
                for node in nodes_data.get('items', []):
                    node_name = node['metadata']['name']
                    conditions = node.get('status', {}).get('conditions', [])
                    ready = any(c['type'] == 'Ready' and c['status'] == 'True' for c in conditions)
                    if not ready:
                        all_ready = False
                        health["errors"].append(f"Node {node_name} is not Ready")
                health["nodes_ready"] = all_ready
                
                # 6. Check core system pods
                try:
                    core_pods_cmd = ["kubectl", "--kubeconfig", "/tmp/health-check-kubeconfig", "get", "pods", "-n", "kube-system", "-o", "json"]
                    pods_result = subprocess.run(core_pods_cmd, capture_output=True, text=True)
                    if pods_result.returncode == 0:
                        pods_data = json.loads(pods_result.stdout)
                        core_components = {"coredns": False, "aws-node": False, "kube-proxy": False}
                        
                        for pod in pods_data.get('items', []):
                            pod_name = pod['metadata']['name']
                            pod_ready = all(c['status'] for c in pod.get('status', {}).get('conditions', []) if c['type'] == 'Ready')
                            
                            for component in core_components:
                                if component in pod_name and pod_ready:
                                    core_components[component] = True
                        
                        all_core_healthy = all(core_components.values())
                        health["core_pods_healthy"] = all_core_healthy
                        
                        for component, is_healthy in core_components.items():
                            if not is_healthy:
                                health["errors"].append(f"Core component {component} is not healthy")
                                
                except Exception as e:
                    logging.debug(f"Could not check core pods: {e}")
                    
            else:
                health["errors"].append(f"Failed to get nodes: {result.stderr}")
        except Exception as e:
            # kubectl check is optional - might not have kubeconfig
            logging.debug(f"Skipping kubectl node check: {e}")
        
        return health

    def _wait_for_cluster_deletion(self, cluster_name: str, region: str, max_wait: int = 600):
        """Wait for cluster to be deleted (max 10 minutes)."""
        start_time = time.time()
        while time.time() - start_time < max_wait:
            status = self._check_cluster_status(cluster_name, region)
            if status is None:
                logging.info(f"Cluster '{cluster_name}' has been deleted")
                return
            elif status == "DELETING":
                logging.info(f"Cluster '{cluster_name}' is still deleting, waiting...")
                time.sleep(30)
            else:
                raise RuntimeError(f"Unexpected cluster status during deletion: {status}")
        
        raise RuntimeError(f"Timeout waiting for cluster '{cluster_name}' deletion")

    # ---------------- public actions ----------------------------------------
    def plan(self, wss: Iterable[str]):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._run("plan", stream_output=True)

    def _handle_access_entry_conflict(self) -> bool:
        """
        Handle EKS access entry conflicts by attempting to import existing resources.
        
        Returns:
            bool: True if conflict was resolved, False otherwise
        """
        try:
            # Get the current workspace configuration
            ws = self._workspace_current()
            cluster_config = self._get_cluster_config(ws)
            cluster_name = cluster_config['name']
            region = cluster_config.get('region', 'us-east-1')
            
            # List existing access entries
            eks_client = boto3.client('eks', region_name=region)
            response = eks_client.list_access_entries(clusterName=cluster_name)
            
            # Look for node group access entries that might be conflicting
            for entry_arn in response.get('accessEntries', []):
                if 'eks-node-group' in entry_arn:
                    logging.info(f"Found existing access entry: {entry_arn}")
                    
                    # Try to import it into terraform state
                    resource_address = "module.karpenter.module.karpenter.aws_eks_access_entry.node[0]"
                    import_id = f"{cluster_name}#{entry_arn}"
                    
                    try:
                        logging.info(f"Attempting to import: {resource_address} with ID: {import_id}")
                        self._run("import", resource_address, import_id)
                        logging.info("Successfully imported existing access entry")
                        return True
                    except Exception as e:
                        logging.warning(f"Failed to import access entry: {e}")
                        # Try removing it instead
                        try:
                            logging.info("Attempting to delete conflicting access entry")
                            eks_client.delete_access_entry(
                                clusterName=cluster_name,
                                principalArn=entry_arn
                            )
                            logging.info("Successfully deleted conflicting access entry")
                            return True
                        except Exception as e2:
                            logging.error(f"Failed to delete access entry: {e2}")
            
            return False
            
        except Exception as e:
            logging.error(f"Error handling access entry conflict: {e}")
            return False

    def _cleanup_crawl_jobs(self):
        """Delete any existing crawl jobs and their pods to prevent Karpenter conflicts."""
        try:
            # Use kubectl to delete crawl jobs
            logging.info("Checking for existing crawl jobs...")
            
            # Delete all jobs with name 'crawl'
            delete_job_cmd = ["kubectl", "delete", "job", "crawl", "--ignore-not-found=true"]
            result = subprocess.run(delete_job_cmd, capture_output=True, text=True)
            if result.returncode == 0 and "deleted" in result.stdout:
                logging.info(f"Deleted crawl job: {result.stdout.strip()}")
            
            # Delete all pods from crawl jobs
            delete_pods_cmd = ["kubectl", "delete", "pods", "-l", "job-name=crawl", "--ignore-not-found=true"]
            result = subprocess.run(delete_pods_cmd, capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                pod_count = len([line for line in result.stdout.strip().split('\n') if 'deleted' in line])
                if pod_count > 0:
                    logging.info(f"Deleted {pod_count} crawl pods")
            
            # Also clean up any stuck NodeClaims
            delete_nodeclaims_cmd = ["kubectl", "delete", "nodeclaims", "--all", "--ignore-not-found=true"]
            result = subprocess.run(delete_nodeclaims_cmd, capture_output=True, text=True)
            if result.returncode == 0 and "deleted" in result.stdout:
                nodeclaim_count = len([line for line in result.stdout.strip().split('\n') if 'deleted' in line])
                if nodeclaim_count > 0:
                    logging.info(f"Deleted {nodeclaim_count} stuck NodeClaims")
                    
        except Exception as e:
            logging.warning(f"Error during crawl job cleanup: {e}")
            # Continue anyway - this is a best-effort cleanup
    
    def _cleanup_karpenter_from_cluster(self):
        """Clean up Karpenter resources from the cluster before reinstalling."""
        try:
            logging.info("Cleaning up Karpenter resources from cluster...")
            
            # Delete NodePools first (they have finalizers)
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
                ["kubectl", "delete", "namespace", "karpenter", "--ignore-not-found=true", "--timeout=60s"]
            ]
            
            for cmd in kubectl_cmds:
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=70)
                    if result.returncode == 0 and result.stdout.strip():
                        logging.info(f"Deleted: {result.stdout.strip()}")
                except subprocess.TimeoutExpired:
                    logging.warning(f"Timeout running: {' '.join(cmd)}")
                except Exception as e:
                    logging.debug(f"Error running {cmd[2]}: {e}")
            
            # Remove Terraform state for Karpenter to ensure clean slate
            try:
                state_rm_cmd = ["terraform", self._chdir, "state", "rm", "module.karpenter"]
                result = subprocess.run(state_rm_cmd, capture_output=True, text=True)
                if result.returncode == 0:
                    logging.info("Removed Karpenter module from Terraform state")
            except Exception as e:
                logging.debug(f"Could not remove Karpenter from state: {e}")
                
        except Exception as e:
            logging.warning(f"Error during Karpenter cleanup: {e}")
            # Continue anyway - we'll try to install fresh

    def _cleanup_orphaned_karpenter_resources(self, cluster_name: str, region: str):
        """Clean up orphaned Karpenter resources from other VPCs.
        
        This handles cases where previous cluster deployments left behind
        resources with Karpenter discovery tags that would interfere with
        the new deployment.
        """
        try:
            ec2 = boto3.client('ec2', region_name=region)
            
            # Get the current cluster's VPC ID
            eks = boto3.client('eks', region_name=region)
            cluster_info = eks.describe_cluster(name=cluster_name)
            current_vpc_id = cluster_info['cluster']['resourcesVpcConfig']['vpcId']
            logging.info(f"Current cluster VPC: {current_vpc_id}")
            
            # Find all security groups with Karpenter discovery tag for this cluster
            karpenter_tag = f"karpenter.sh/discovery"
            sg_response = ec2.describe_security_groups(
                Filters=[
                    {'Name': f'tag:{karpenter_tag}', 'Values': [cluster_name]}
                ]
            )
            
            # Remove tags from security groups in other VPCs
            for sg in sg_response['SecurityGroups']:
                if sg['VpcId'] != current_vpc_id:
                    logging.info(f"Removing Karpenter tag from security group {sg['GroupId']} in VPC {sg['VpcId']}")
                    try:
                        ec2.delete_tags(
                            Resources=[sg['GroupId']],
                            Tags=[{'Key': karpenter_tag, 'Value': cluster_name}]
                        )
                    except Exception as e:
                        logging.warning(f"Failed to remove tag from {sg['GroupId']}: {e}")
            
            # Find all subnets with Karpenter discovery tag for this cluster
            subnet_response = ec2.describe_subnets(
                Filters=[
                    {'Name': f'tag:{karpenter_tag}', 'Values': [cluster_name]}
                ]
            )
            
            # Remove tags from subnets in other VPCs
            for subnet in subnet_response['Subnets']:
                if subnet['VpcId'] != current_vpc_id:
                    logging.info(f"Removing Karpenter tag from subnet {subnet['SubnetId']} in VPC {subnet['VpcId']}")
                    try:
                        ec2.delete_tags(
                            Resources=[subnet['SubnetId']],
                            Tags=[{'Key': karpenter_tag, 'Value': cluster_name}]
                        )
                    except Exception as e:
                        logging.warning(f"Failed to remove tag from {subnet['SubnetId']}: {e}")
                        
            logging.info("Completed cleanup of orphaned Karpenter resources")
            
        except Exception as e:
            logging.warning(f"Error during orphaned resource cleanup: {e}")
            # Continue anyway - this is a best-effort cleanup

    def create(self, wss: Iterable[str]):
        for ws in wss:
            # Check if cluster already exists
            status = None
            try:
                cluster_config = self._get_cluster_config(ws)
                cluster_name = cluster_config['name']
                region = cluster_config.get('region', 'us-east-1')
                status = self._check_cluster_status(cluster_name, region)
                
                if status == "ACTIVE":
                    logging.info(f"Cluster '{cluster_name}' already exists and is ACTIVE in region {region}.")
                    
                    # Perform comprehensive health checks
                    logging.info("Performing health checks on existing cluster...")
                    health = self._check_cluster_health(cluster_name, region)
                    
                    # Log health check results
                    logging.info(f"Health check results:")
                    logging.info(f"  - Status: {health['status']}")
                    logging.info(f"  - API Accessible: {health['api_accessible']}")
                    logging.info(f"  - Authentication: {health['auth_working']}")
                    logging.info(f"  - Node Groups: {'Healthy' if health['node_groups_healthy'] else 'Issues detected'}")
                    logging.info(f"  - Nodes Ready: {health['nodes_ready']}")
                    
                    if health['errors']:
                        logging.warning("Health check issues found:")
                        for error in health['errors']:
                            logging.warning(f"  - {error}")
                    
                    # Determine if cluster is healthy enough to proceed
                    is_healthy = (
                        health['status'] == 'ACTIVE' and
                        health['api_accessible'] and
                        health['auth_working'] and
                        health['node_groups_healthy']
                    )
                    
                    if not is_healthy:
                        logging.error("Cluster health checks failed. Will destroy and recreate the cluster.")
                        self._workspace_select_or_create(ws)
                        self.destroy([ws], force=True)
                        self._wait_for_cluster_deletion(cluster_name, region)
                    else:
                        logging.info("Cluster is healthy - will recreate Karpenter resources...")
                        # Select workspace but don't destroy the cluster
                        self._workspace_select_or_create(ws)
                        
                        # Update kubeconfig first
                        update_kubeconfig_cmd = [
                            "aws", "eks", "update-kubeconfig",
                            "--name", cluster_name,
                            "--region", region
                        ]
                        subprocess.run(update_kubeconfig_cmd, capture_output=True)
                        
                        # Clean up existing Karpenter installation
                        logging.info("Cleaning up existing Karpenter installation...")
                        self._cleanup_karpenter_from_cluster()
                elif status == "DELETING":
                    logging.info(f"Cluster '{cluster_name}' is being deleted in region {region}. Waiting for deletion to complete...")
                    self._wait_for_cluster_deletion(cluster_name, region)
                elif status is not None:
                    logging.warning(f"Cluster '{cluster_name}' exists with unexpected status: {status}. Will destroy and recreate.")
                    self._workspace_select_or_create(ws)
                    self.destroy([ws], force=True)
                    self._wait_for_cluster_deletion(cluster_name, region)
                
            except Exception as e:
                logging.warning(f"Could not check cluster status for workspace '{ws}': {e}. Proceeding with terraform apply.")
            
            # Always select workspace and apply
            self._workspace_select_or_create(ws)
            
            # Apply in stages to avoid timeouts
            logging.info(f"Creating cluster for workspace '{ws}'...")
            
            # Stage 1: Create the EKS cluster and node groups
            logging.info("Stage 1: Creating EKS cluster and node groups...")
            self._run("apply", "-auto-approve", "-target", "module.cluster", stream_output=True)
            
            # Stage 2: Install Karpenter
            logging.info("Stage 2: Installing Karpenter...")
            
            # Delete any existing crawl jobs to prevent node provisioning conflicts
            logging.info("Cleaning up any existing crawl jobs...")
            self._cleanup_crawl_jobs()
            
            # Clean up orphaned Karpenter resources from other VPCs
            logging.info("Checking for orphaned Karpenter resources...")
            self._cleanup_orphaned_karpenter_resources(cluster_name, region)
            
            # Debug: Test cluster connectivity first
            logging.info("Testing cluster connectivity before Karpenter installation...")
            try:
                # Get cluster info from the workspace config
                cluster_config = self._get_cluster_config(ws)
                cluster_name = cluster_config['name']
                region = cluster_config.get('region', 'us-east-1')
                
                test_cmd = [
                    "aws", "eks", "get-token", 
                    "--cluster-name", cluster_name, 
                    "--region", region
                ]
                result = subprocess.run(test_cmd, capture_output=True, text=True, timeout=30)
                if result.returncode == 0:
                    logging.info("Successfully generated EKS token")
                else:
                    logging.error(f"Failed to generate EKS token: {result.stderr}")
                    
                # Also test cluster describe
                describe_cmd = [
                    "aws", "eks", "describe-cluster",
                    "--name", cluster_name,
                    "--region", region,
                    "--query", "cluster.endpoint"
                ]
                result = subprocess.run(describe_cmd, capture_output=True, text=True, timeout=30)
                if result.returncode == 0:
                    logging.info(f"Cluster endpoint: {result.stdout.strip()}")
                else:
                    logging.error(f"Failed to describe cluster: {result.stderr}")
                    
            except subprocess.TimeoutExpired:
                logging.error("Timeout while testing cluster - this indicates connectivity issues")
            except Exception as e:
                logging.error(f"Error testing cluster connectivity: {e}")
            
            # Try to apply Karpenter module with error handling for access entry conflicts
            try:
                self._run("apply", "-auto-approve", "-target", "module.karpenter", stream_output=True)
            except RuntimeError as e:
                error_str = str(e)
                # Check if this is an access entry conflict
                if "ResourceInUseException" in error_str and "access entry" in error_str:
                    logging.warning("EKS access entry conflict detected, attempting to resolve...")
                    if self._handle_access_entry_conflict():
                        logging.info("Resolved access entry conflict, retrying apply...")
                        self._run("apply", "-auto-approve", "-target", "module.karpenter", stream_output=True)
                    else:
                        raise
                else:
                    raise
            
            # Stage 3: Apply any remaining resources
            logging.info("Stage 3: Applying remaining resources...")
            self._run("apply", "-auto-approve", stream_output=True)

    def destroy(self, wss: Iterable[str], force: bool = False):
        """Remove the selected workspaces.

        A two-step destroy is performed:

        1. Try to delete the Karpenter Helm release and its CRs explicitly
           (they often hold finalizers that would block the full destroy).
           Errors in this step are logged but do **not** abort the run.
        2. Run a normal, unconditional `terraform destroy`.
        
        If force=True, remove ALL resources from state and use AWS APIs directly.
        """
        for ws in wss:
            self._workspace_select_or_create(ws)
            
            # Get cluster info before destroy
            try:
                cluster_config = self._get_cluster_config(ws)
                cluster_name = cluster_config['name']
                region = cluster_config.get('region', 'us-east-1')
            except Exception as e:
                logging.warning(f"Could not get cluster config: {e}")
                cluster_name = None
                region = 'us-east-1'

            # If force destroy, be very aggressive
            if force:
                logging.info("FORCE DESTROY: Removing all Kubernetes-related resources from state")
                
                # Get all resources in state
                list_cmd = ["terraform", self._chdir, "state", "list"]
                result = subprocess.run(list_cmd, text=True, capture_output=True)
                
                if result.returncode == 0:
                    all_resources = result.stdout.strip().split('\n')
                    
                    # Remove ALL helm, kubectl, and kubernetes resources
                    for resource in all_resources:
                        if any(x in resource for x in ['helm_release', 'kubectl_manifest', 'kubernetes_']):
                            try:
                                remove_cmd = ["terraform", self._chdir, "state", "rm", resource]
                                rm_result = subprocess.run(remove_cmd, text=True, capture_output=True)
                                if rm_result.returncode == 0:
                                    logging.info(f"Removed {resource} from state")
                            except Exception as e:
                                logging.debug(f"Could not remove {resource}: {e}")
                
                # Force terminate all EC2 instances for this cluster
                if cluster_name:
                    logging.info(f"FORCE DESTROY: Terminating all EC2 instances for cluster {cluster_name}")
                    try:
                        ec2 = boto3.client('ec2', region_name=region)
                        
                        # Find all instances with cluster tags
                        instances = ec2.describe_instances(
                            Filters=[
                                {'Name': 'tag:kubernetes.io/cluster/' + cluster_name, 'Values': ['owned']},
                                {'Name': 'instance-state-name', 'Values': ['running', 'pending', 'stopping', 'stopped']}
                            ]
                        )
                        
                        instance_ids = []
                        for reservation in instances['Reservations']:
                            for instance in reservation['Instances']:
                                instance_ids.append(instance['InstanceId'])
                        
                        if instance_ids:
                            logging.info(f"Force terminating {len(instance_ids)} instances: {instance_ids}")
                            ec2.terminate_instances(InstanceIds=instance_ids)
                    except Exception as e:
                        logging.warning(f"Could not force terminate instances: {e}")
                    
                    # Delete node groups directly
                    try:
                        eks = boto3.client('eks', region_name=region)
                        nodegroups = eks.list_nodegroups(clusterName=cluster_name).get('nodegroups', [])
                        for ng in nodegroups:
                            logging.info(f"Force deleting node group: {ng}")
                            try:
                                eks.delete_nodegroup(clusterName=cluster_name, nodegroupName=ng)
                            except Exception as e:
                                logging.debug(f"Could not delete node group {ng}: {e}")
                    except Exception as e:
                        logging.debug(f"Could not list/delete node groups: {e}")
            else:
                # Normal destroy - try Karpenter first
                karpenter_targets = [
                    "-target", "module.karpenter.helm_release.karpenter",
                    "-target", "module.karpenter.kubectl_manifest.karpenter_nodepool",
                    "-target", "module.karpenter.kubectl_manifest.karpenter_node_class",
                ]
                try:
                    self._run("destroy", "-auto-approve", *karpenter_targets, stream_output=True)
                except RuntimeError as exc:
                    logging.warning("targeted Karpenter destroy failed in workspace '%s': %s", ws, exc)

            # Always run terraform destroy with refresh=false to avoid auth issues
            try:
                self._run("destroy", "-auto-approve", "-refresh=false", stream_output=True)
            except RuntimeError as exc:
                if force:
                    logging.warning(f"Terraform destroy failed, but continuing with force cleanup: {exc}")
                else:
                    raise

            # Always cleanup orphan ENIs
            try:
                _delete_orphan_enis(tag_keys=_get_tag_keys())
            except Exception as exc:
                logger.warning("Orphan-ENI cleanup failed: %s", exc)


    def resize(self, wss: Iterable[str], level: InstanceLevel):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._update_level(level)
            self._run("apply", "-auto-approve", stream_output=True)
    
    def health_check(self, wss: Iterable[str]):
        """Perform health checks on specified clusters."""
        overall_healthy = True
        
        for ws in wss:
            try:
                cluster_config = self._get_cluster_config(ws)
                cluster_name = cluster_config['name']
                region = cluster_config.get('region', 'us-east-1')
                
                logging.info(f"\n{'='*60}")
                logging.info(f"Health check for cluster: {cluster_name} ({region})")
                logging.info(f"{'='*60}")
                
                # Check if cluster exists
                status = self._check_cluster_status(cluster_name, region)
                if status is None:
                    logging.error(f"Cluster '{cluster_name}' does not exist")
                    overall_healthy = False
                    continue
                
                # Perform comprehensive health check
                health = self._check_cluster_health(cluster_name, region)
                
                # Display results
                logging.info(f"Status: {health['status']}")
                logging.info(f"API Server: {'✓ Accessible' if health['api_accessible'] else '✗ Not accessible'}")
                logging.info(f"Authentication: {'✓ Working' if health['auth_working'] else '✗ Failed'}")
                logging.info(f"Node Groups: {'✓ Healthy' if health['node_groups_healthy'] else '✗ Issues detected'}")
                logging.info(f"Nodes: {'✓ All Ready' if health['nodes_ready'] else '✗ Some not ready'}")
                logging.info(f"Core Pods: {'✓ Healthy' if health['core_pods_healthy'] else '✗ Issues detected'}")
                
                if health['errors']:
                    logging.error("Issues found:")
                    for error in health['errors']:
                        logging.error(f"  - {error}")
                
                # Determine overall health
                is_healthy = (
                    health['status'] == 'ACTIVE' and
                    health['api_accessible'] and
                    health['auth_working'] and
                    health['node_groups_healthy']
                )
                
                if is_healthy:
                    logging.info(f"✓ Cluster '{cluster_name}' is HEALTHY")
                else:
                    logging.error(f"✗ Cluster '{cluster_name}' is UNHEALTHY")
                    overall_healthy = False
                    
            except Exception as e:
                logging.error(f"Failed to check health for workspace '{ws}': {e}")
                overall_healthy = False
        
        return overall_healthy

    # ---------------- helpers ------------------------------------------------
    def _update_level(self, level: InstanceLevel):
        tfvars = self.wd / "terraform.tfvars.json"
        if not tfvars.exists():
            raise ParameterValidationError(f"{tfvars} missing – cannot resize")
        with tfvars.open() as fp:
            data = json.load(fp)
        data["cluster_level"] = level.value
        tfvars.write_text(json.dumps(data, indent=2))
        logging.info("cluster_level set to %s", level.value)


# ─────────────────────────────────────────────────────────────────────────────
# CLI entry-point
# ─────────────────────────────────────────────────────────────────────────────
def main():
    logging.basicConfig(level=os.getenv("LOGLEVEL", "INFO"))

    action = (os.getenv("ACTION") or "").lower()
    if not action:
        raise ParameterValidationError("ACTION env var not set")

    clusters = _clusters_from_config()

    # Script is now inside crawl_infrastructure directory
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
    elif action == "health" or action == "health_check":
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

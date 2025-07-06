#!/usr/bin/env python3
"""
cluster_manager.py – run Terraform inside ./crawl_infrastructure

Configuration hierarchy
-----------------------
1. Environment variables
   * ACTION    – create | plan | destroy | resize  (required)
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
    def _run(self, *args: str):
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s", " ".join(cmd))
        result = subprocess.run(cmd, text=True, capture_output=True)
        
        # Check for state lock error and handle it
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
            self._run("plan")

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
                    logging.info("Proceeding to create any missing resources...")
                    # Continue with terraform apply to create missing resources
                elif status == "DELETING":
                    logging.info(f"Cluster '{cluster_name}' is being deleted in region {region}. Waiting for deletion to complete...")
                    self._wait_for_cluster_deletion(cluster_name, region)
                elif status is not None:
                    logging.warning(f"Cluster '{cluster_name}' exists with unexpected status: {status}. Proceeding with terraform apply.")
                
            except Exception as e:
                logging.warning(f"Could not check cluster status for workspace '{ws}': {e}. Proceeding with terraform apply.")
            
            # Always select workspace and apply
            self._workspace_select_or_create(ws)
            
            # Update kubeconfig if cluster is active
            if status == "ACTIVE":
                try:
                    cluster_config = self._get_cluster_config(ws)
                    cluster_name = cluster_config['name']
                    region = cluster_config.get('region', 'us-east-1')
                    
                    # Update kubeconfig to ensure authentication works
                    logging.info(f"Updating kubeconfig for existing cluster '{cluster_name}'...")
                    update_cmd = ["aws", "eks", "update-kubeconfig", "--name", cluster_name, "--region", region]
                    result = subprocess.run(update_cmd, text=True, capture_output=True)
                    if result.returncode != 0:
                        logging.warning(f"Failed to update kubeconfig: {result.stderr}")
                    else:
                        logging.info("Kubeconfig updated successfully")
                    
                    # Refresh only the cluster module first to populate outputs
                    logging.info("Refreshing terraform state for cluster module...")
                    try:
                        self._run("refresh", "-target=module.cluster")
                        logging.info("Cluster module refresh completed successfully")
                        
                        # Now refresh the rest
                        logging.info("Refreshing remaining terraform state...")
                        self._run("refresh")
                        logging.info("Full state refresh completed successfully")
                    except Exception as e:
                        logging.warning(f"State refresh failed: {e}. Continuing with apply...")
                except Exception as e:
                    logging.warning(f"Failed to handle existing cluster: {e}. Continuing with apply...")
            
            # Apply to create any missing resources
            self._run("apply", "-auto-approve")

    def destroy(self, wss: Iterable[str]):
        """Remove the selected workspaces.

        A two-step destroy is performed:

        1. Try to delete the Karpenter Helm release and its CRs explicitly
           (they often hold finalizers that would block the full destroy).
           Errors in this step are logged but do **not** abort the run.
        2. Run a normal, unconditional `terraform destroy`.
        """
        # Targets that frequently need explicit removal first
        karpenter_targets: list[str] = [
            "-target",
            "module.karpenter.helm_release.karpenter",
            "-target",
            "module.karpenter.kubectl_manifest.karpenter_nodepool",
            "-target",
            "module.karpenter.kubectl_manifest.karpenter_node_class",
        ]

        for ws in wss:
            self._workspace_select_or_create(ws)

            # Step 1: best-effort cleanup of Karpenter resources
            try:
                self._run("destroy", "-auto-approve", *karpenter_targets)
            except RuntimeError as exc:
                # Log and continue – the full destroy will take care of leftovers
                logging.warning(
                    "targeted Karpenter destroy failed in workspace '%s': %s", ws, exc
                )

            # Step 2: remove everything else
            self._run("destroy", "-auto-approve")

            # Step 3 – orphan ENI cleanup
            try:
                _delete_orphan_enis(tag_keys=_get_tag_keys())
            except Exception as exc:  # never abort overall destroy
                logger.warning("Orphan-ENI cleanup failed: %s", exc)


    def resize(self, wss: Iterable[str], level: InstanceLevel):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._update_level(level)
            self._run("apply", "-auto-approve")

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

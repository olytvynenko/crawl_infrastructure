"""
Terraform execution: run commands, workspace selection, lock handling, tfvars config.
"""
from __future__ import annotations

import json
import logging
import re
import subprocess
from pathlib import Path
from typing import Optional

from .config import InstanceLevel, ParameterValidationError

logger = logging.getLogger(__name__)


class TerraformRunner:
    """Runs Terraform in a given working directory with workspace and lock handling."""

    def __init__(self, working_directory: str | Path) -> None:
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' not found")
        self._chdir = f"-chdir={self.wd}"
        logger.debug("Terraform chdir flag: %s", self._chdir)

    def run_capture(self, *args: str) -> tuple[int, str, str]:
        """Run terraform and return (returncode, stdout, stderr)."""
        cmd = ["terraform", self._chdir, *args]
        result = subprocess.run(cmd, text=True, capture_output=True)
        return result.returncode, result.stdout, result.stderr

    def run(self, *args: str, stream_output: bool = False) -> None:
        cmd = ["terraform", self._chdir, *args]
        logger.debug("$ %s", " ".join(cmd))

        if stream_output:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                universal_newlines=True,
            )
            output_lines = []
            for line in process.stdout:
                print(line, end="")
                output_lines.append(line)
            process.wait()
            output = "".join(output_lines)

            if process.returncode != 0:
                if "Error acquiring the state lock" in output or "Error releasing the state lock" in output:
                    lock_id = self._extract_lock_id(output)
                    if lock_id:
                        logger.warning("State lock detected (ID: %s). Attempting to unlock...", lock_id)
                        self._force_unlock(lock_id)
                        logger.info("Retrying command after unlocking state...")
                        self.run(*args, stream_output=stream_output)
                        return
                error_msg = f"terraform {args[0]} failed (exit {process.returncode})"
                if "ResourceInUseException" in output:
                    error_lines = [
                        line for line in output_lines
                        if "Error:" in line or "ResourceInUseException" in line
                    ]
                    if error_lines:
                        error_msg += f" - {' '.join(error_lines[-5:])}"
                raise RuntimeError(error_msg)
        else:
            result = subprocess.run(cmd, text=True, capture_output=True)
            if result.returncode != 0:
                err = result.stderr or ""
                if "Error acquiring the state lock" in err or "Error releasing the state lock" in err:
                    lock_id = self._extract_lock_id(err)
                    if lock_id:
                        logger.warning("State lock detected (ID: %s). Attempting to unlock...", lock_id)
                        self._force_unlock(lock_id)
                        logger.info("Retrying command after unlocking state...")
                        result = subprocess.run(cmd, text=True, capture_output=True)
                        if result.returncode == 0:
                            logger.info("Command succeeded after unlocking state")
                            return
                logger.error("Command failed: %s", result.stderr)
                raise RuntimeError(f"terraform {args[0]} failed (exit {result.returncode})")

    def _extract_lock_id(self, error_text: str) -> Optional[str]:
        match = re.search(r"ID:\s+([a-f0-9-]+)", error_text)
        if match:
            return match.group(1)
        match = re.search(r'lock ID\s+"([a-f0-9-]+)"', error_text)
        return match.group(1) if match else None

    def _force_unlock(self, lock_id: str) -> None:
        unlock_cmd = ["terraform", self._chdir, "force-unlock", "-force", lock_id]
        logger.debug("$ %s", " ".join(unlock_cmd))
        result = subprocess.run(unlock_cmd, text=True, capture_output=True)
        if result.returncode == 0:
            logger.info("Successfully unlocked state (ID: %s)", lock_id)
        else:
            logger.error("Failed to unlock state: %s", result.stderr)
            raise RuntimeError(f"Failed to unlock terraform state (ID: {lock_id})")

    def workspace_select_or_create(self, ws: str) -> None:
        try:
            self.run("workspace", "select", ws)
            logger.info("Selected workspace '%s'", ws)
        except RuntimeError:
            logger.info("Workspace '%s' missing – creating", ws)
            self.run("workspace", "new", ws)

    def workspace_current(self) -> str:
        """Return the current Terraform workspace name."""
        result = subprocess.run(
            ["terraform", self._chdir, "workspace", "show"],
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout.strip()

    def get_cluster_config(self, workspace: str) -> dict:
        """Get cluster configuration from terraform.tfvars.json for the given workspace."""
        tfvars_path = self.wd / "terraform.tfvars.json"
        with open(tfvars_path) as f:
            config = json.load(f)
        if workspace not in config.get("clusters", {}):
            raise ParameterValidationError(
                f"Workspace '{workspace}' not found in terraform.tfvars.json"
            )
        return config["clusters"][workspace]

    def update_level(self, level: InstanceLevel) -> None:
        tfvars = self.wd / "terraform.tfvars.json"
        if not tfvars.exists():
            raise ParameterValidationError(f"{tfvars} missing – cannot resize")
        with tfvars.open() as fp:
            data = json.load(fp)
        data["cluster_level"] = level.value
        tfvars.write_text(json.dumps(data, indent=2))
        logger.info("cluster_level set to %s", level.value)

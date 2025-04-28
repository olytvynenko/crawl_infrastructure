#!/usr/bin/env python3
"""cluster_manager.py

Utility wrapper that drives Terraform workspaces so you can *create*, *destroy*,
*plan* or *resize* clusters from automation (AWS CodeBuild, GitHub Actions, cron, …).

The script is fully controlled by **environment variables** so a single
CodeBuild project can run every action you need:

* **ACTION**          – `plan` | `apply` | `create` | `destroy` | `resize`
* **CLUSTERS**        – comma‑separated list of workspace names (e.g. "nc,nv,ohio")
* **LEVEL** (optional) – new worker level for the *resize* action.

Requirements
------------
* Terraform already installed in the running container/host.
* Python ≥ 3.10 (for `subprocess.run(..., text=True, capture_output=True)`)
* A file called `terraform.tfvars.json.bak` in the working directory that holds
  the **template** variable set. The script makes a copy, changes the single
  field *cluster_level*, applies, then discards the temp file.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from enum import Enum
from pathlib import Path
from typing import Iterable, List


class ParameterValidationError(ValueError):
    """Raised when a required argument is missing or invalid."""


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


# ------------------------------------------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------------------------------------------

def _run(cmd: List[str], cwd: Path | str) -> None:
    """Run *cmd* in *cwd*. Raises if Terraform exits with a non‑zero code."""
    logging.debug("$ %s", " ".join(cmd))
    proc = subprocess.run(cmd, cwd=cwd, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command {' '.join(cmd)} failed with code {proc.returncode}")


def _select_or_create(workspace: str, cwd: Path | str) -> None:
    """Select the workspace or create it if it does not yet exist."""
    result = subprocess.run(
        ["terraform", "workspace", "select", workspace],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        logging.info("Workspace '%s' missing – creating", workspace)
        _run(["terraform", "workspace", "new", workspace], cwd)
    else:
        logging.info("Selected workspace '%s'", workspace)


# ------------------------------------------------------------------------------------------------------------------
# main class
# ------------------------------------------------------------------------------------------------------------------

class ClusterManager:
    def __init__(self, working_directory: str | Path):
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' does not exist")
        logging.debug("Working directory: %s", self.wd)

    # ---------------- public actions ------------------------------------------------------
    def plan(self, workspaces: Iterable[str]):
        self._foreach(workspaces, ["terraform", "plan"])

    def create(self, workspaces: Iterable[str]):
        self._foreach(workspaces, ["terraform", "apply", "-auto-approve"])

    def destroy(self, workspaces: Iterable[str]):
        self._foreach(workspaces, ["terraform", "destroy", "-auto-approve"])

    def resize(self, workspaces: Iterable[str], level: InstanceLevel):
        for ws in workspaces:
            _select_or_create(ws, self.wd)
            self._set_workers_level(level)
            _run(["terraform", "apply", "-auto-approve"], self.wd)

    # ---------------- internals -----------------------------------------------------------
    def _foreach(self, workspaces: Iterable[str], tf_cmd: List[str]):
        workspaces = list(workspaces)
        if not workspaces:
            raise ParameterValidationError("CLUSTERS list is empty")
        for ws in workspaces:
            _select_or_create(ws, self.wd)
            _run(tf_cmd, self.wd)

    def _set_workers_level(self, level: InstanceLevel):
        backup_file = self.wd / "terraform.tfvars.json.bak"
        live_file = self.wd / "terraform.tfvars.json"
        if not backup_file.exists():
            raise ParameterValidationError(f"{backup_file} not found – cannot resize")
        with backup_file.open() as fp:
            variables = json.load(fp)
        variables["cluster_level"] = level.value
        live_file.write_text(json.dumps(variables, indent=2))
        logging.info("cluster_level set to %s", level.value)


# ------------------------------------------------------------------------------------------------------------------
# entry‑point
# ------------------------------------------------------------------------------------------------------------------

def _parse_env_list(name: str) -> List[str]:
    val = os.environ.get(name)
    if not val:
        raise ParameterValidationError(f"environment variable '{name}' is required")
    return [item.strip() for item in val.split(",") if item.strip()]


def main() -> None:
    logging.basicConfig(level=os.environ.get("LOGLEVEL", "INFO"))

    action = os.environ.get("ACTION") or os.environ.get("action")
    if not action:
        raise ParameterValidationError("ACTION environment variable not set")
    action = action.lower()

    clusters = _parse_env_list("CLUSTERS" if "CLUSTERS" in os.environ else "clusters")

    manager = ClusterManager("./crawl_infrastructure")

    if action in {"create", "apply"}:
        manager.create(clusters)
    elif action == "destroy":
        manager.destroy(clusters)
    elif action == "plan":
        manager.plan(clusters)
    elif action == "resize":
        level_str = os.environ.get("LEVEL") or os.environ.get("level")
        if not level_str:
            raise ParameterValidationError("LEVEL env‑var required when ACTION=resize")
        level = InstanceLevel.from_str(level_str)
        manager.resize(clusters, level)
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

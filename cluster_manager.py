#!/usr/bin/env python3
"""cluster_manager.py

Runs Terraform *inside* the `crawl_infrastructure/` directory no matter where
this script is launched from.  Supported actions (via env‑vars):

* **ACTION**   – `plan` | `create` | `destroy` | `resize`
* **CLUSTERS** – comma‑separated list of workspace names
* **LEVEL**    – Instance level for `resize`

The script always invokes Terraform as

```bash
terraform -chdir=<repo‑root>/crawl_infrastructure …
```

so you never worry about `cd`.
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

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

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


def _run(cmd: List[str]) -> None:  # runs with inherited cwd
    logging.debug("$ %s", " ".join(cmd))
    proc = subprocess.run(cmd, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command {' '.join(cmd)} failed with code {proc.returncode}")


# ---------------------------------------------------------------------------
# main driver
# ---------------------------------------------------------------------------

class ClusterManager:
    def __init__(self, working_directory: str | Path):
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' does not exist")
        self._chdir_flag = f"-chdir={self.wd}"
        logging.debug("Terraform chdir flag: %s", self._chdir_flag)

    # ------------- terraform wrappers ---------------------------------------------------
    def _tf(self, *args: str):
        """Call Terraform with the `-chdir` flag pre‑applied."""
        _run(["terraform", self._chdir_flag, *args])

    def _workspace_select_or_create(self, name: str):
        """Select the workspace; create it if it isn’t there yet."""
        try:
            self._tf("workspace", "select", name)
            logging.info("Selected workspace '%s'", name)
        except RuntimeError:
            logging.info("Workspace '%s' missing – creating", name)
            self._tf("workspace", "new", name)

    # ------------- public actions -------------------------------------------------------
    def plan(self, workspaces: Iterable[str]):
        for ws in workspaces:
            self._workspace_select_or_create(ws)
            self._tf("plan")

    def create(self, workspaces: Iterable[str]):
        for ws in workspaces:
            self._workspace_select_or_create(ws)
            self._tf("apply", "-auto-approve")

    def destroy(self, workspaces: Iterable[str]):
        for ws in workspaces:
            self._workspace_select_or_create(ws)
            self._tf("destroy", "-auto-approve")

    def resize(self, workspaces: Iterable[str], level: InstanceLevel):
        for ws in workspaces:
            self._workspace_select_or_create(ws)
            self._set_workers_level(level)
            self._tf("apply", "-auto-approve")

    # ------------- internals -----------------------------------------------------------
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


# ---------------------------------------------------------------------------
# CLI entry‑point
# ---------------------------------------------------------------------------

def _parse_env_list(name: str) -> List[str]:
    val = os.environ.get(name)
    if not val:
        raise ParameterValidationError(f"environment variable '{name}' is required")
    return [item.strip() for item in val.split(',') if item.strip()]


def main() -> None:
    logging.basicConfig(level=os.environ.get("LOGLEVEL", "INFO"))

    action = (os.environ.get("ACTION") or os.environ.get("action") or "").lower()
    if not action:
        raise ParameterValidationError("ACTION environment variable not set")

    clusters = _parse_env_list("CLUSTERS" if "CLUSTERS" in os.environ else "clusters")

    mgr = ClusterManager("./crawl_infrastructure")

    if action in {"create", "apply"}:
        mgr.create(clusters)
    elif action == "destroy":
        mgr.destroy(clusters)
    elif action == "plan":
        mgr.plan(clusters)
    elif action == "resize":
        level_str = os.environ.get("LEVEL") or os.environ.get("level")
        if not level_str:
            raise ParameterValidationError("LEVEL env‑var required when ACTION=resize")
        mgr.resize(clusters, InstanceLevel.from_str(level_str))
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

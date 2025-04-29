#!/usr/bin/env python3
"""cluster_manager.py – run Terraform inside ./crawl_infrastructure

NO automatic copy of *terraform.tfvars.json.bak*.
The script assumes a valid **terraform.tfvars.json** already exists alongside
your *.tf* files. If it is missing, the run fails fast with a clear error.

Env‑vars
--------
ACTION   – create | plan | destroy | resize
CLUSTERS – comma‑separated workspace list
LEVEL    – inst4 | inst8 | inst16 (required for resize)
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
# Cluster manager
# ─────────────────────────────────────────────────────────────────────────────

class ClusterManager:
    def __init__(self, working_directory: str | Path):
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' not found")
        self._chdir = f"-chdir={self.wd}"
        logging.debug("Terraform chdir flag: %s", self._chdir)

    # ------------- internal runners -----------------------------------------
    def _run(self, *args: str):
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s", " ".join(cmd))
        result = subprocess.run(cmd, text=True)
        if result.returncode != 0:
            raise RuntimeError("terraform %s failed (exit %d)" % (args[0], result.returncode))

    def _workspace_select_or_create(self, ws: str):
        if self._run("workspace", "select", ws) is None:
            logging.info("Selected workspace '%s'", ws)
            return
        logging.info("Workspace '%s' missing – creating", ws)
        self._run("workspace", "new", ws)

    # ------------- public actions -------------------------------------------
    def plan(self, wss: Iterable[str]):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._run("plan")

    def create(self, wss: Iterable[str]):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._run("apply", "-auto-approve")

    def destroy(self, wss: Iterable[str]):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._run("destroy", "-auto-approve")

    def resize(self, wss: Iterable[str], level: InstanceLevel):
        for ws in wss:
            self._workspace_select_or_create(ws)
            self._update_level(level)
            self._run("apply", "-auto-approve")

    # ------------- helpers --------------------------------------------------
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
# CLI entry‑point
# ─────────────────────────────────────────────────────────────────────────────

def _csv(name: str) -> List[str]:
    val = os.getenv(name)
    if not val:
        raise ParameterValidationError(f"env var '{name}' missing")
    return [x.strip() for x in val.split(',') if x.strip()]


def main():
    logging.basicConfig(level=os.getenv("LOGLEVEL", "INFO"))

    action = (os.getenv("ACTION") or "").lower()
    if not action:
        raise ParameterValidationError("ACTION env var not set")

    clusters = _csv("CLUSTERS")
    mgr = ClusterManager("./crawl_infrastructure")

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

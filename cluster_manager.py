#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  Cluster Manager – thin wrapper around “terraform workspace/apply/destroy”
# ─────────────────────────────────────────────────────────────────────────────
from __future__ import annotations

import argparse
import logging
import subprocess
import sys
from pathlib import Path

from exceptions import ParameterValidationError

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s",
    stream=sys.stdout,
)


class ClusterManager:
    """
    Operates a Terraform stack located in *working_directory*.
    Keeps all Terraform commands isolated with the `-chdir=` flag so the
    script can be invoked from any path.
    """

    # ───────────────────────────────────────────
    # Construction
    # ───────────────────────────────────────────
    def __init__(self, working_directory: str | Path) -> None:
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' not found")
        self._chdir = f"-chdir={self.wd}"
        logging.debug("Terraform chdir flag: %s", self._chdir)

    # ───────────────────────────────────────────
    # Internal helpers
    # ───────────────────────────────────────────
    def _run(self, *args: str) -> None:
        """Run *terraform <args>* – raise on non-zero exit code."""
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s", " ".join(cmd))
        result = subprocess.run(cmd, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"terraform {args[0]} failed (exit {result.returncode})")

    def _try(self, *args: str) -> bool:
        """Same as _run but return *True*/*False* instead of raising."""
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s (try)", " ".join(cmd))
        result = subprocess.run(cmd, text=True)
        return result.returncode == 0

    # ───────────────────────────────────────────
    # Workspace handling
    # ───────────────────────────────────────────
    def _workspace_select_or_create(self, ws: str) -> None:
        """
        Select *ws* if it exists, otherwise create it.
        Uses `terraform workspace select -or-create` which is atomic and
        prevents TOCTOU races.
        """
        self._run("workspace", "select", "-or-create", ws)

    # ───────────────────────────────────────────
    # Public operations
    # ───────────────────────────────────────────
    def apply(self, ws: str) -> None:
        """
        Initialise, select workspace, then run “terraform apply”.
        """
        logging.info("Applying stack in %s (workspace: %s)", self.wd, ws)
        self._run("init", "-input=false", "-upgrade")
        self._workspace_select_or_create(ws)
        self._run("apply", "-auto-approve")

    def destroy(self, workspaces: list[str]) -> None:
        """
        Destroy the stack for each workspace in *workspaces*.
        The backend is initialised first so Terraform can list/select remote
        workspaces even when invoked in a fresh directory (e.g. CodeBuild).
        """
        logging.info("Destroying stack in %s", self.wd)
        self._run("init", "-input=false", "-upgrade")

        for ws in workspaces:
            logging.info("→ Workspace '%s'", ws)
            # The flag handles both select and create (noop if already there)
            self._workspace_select_or_create(ws)
            self._run("destroy", "-auto-approve")

    # ───────────────────────────────────────────
    # Convenience wrappers for CLI
    # ───────────────────────────────────────────
    @classmethod
    def cli(cls) -> None:
        parser = argparse.ArgumentParser(description="Terraform cluster manager")
        sub = parser.add_subparsers(dest="command", required=True)

        p_apply = sub.add_parser("apply", help="terraform apply")
        p_apply.add_argument("workspace", help="workspace to apply")

        p_destroy = sub.add_parser("destroy", help="terraform destroy")
        p_destroy.add_argument(
            "workspaces",
            nargs="+",
            help="one or more workspaces to destroy",
        )

        p_init = sub.add_parser("init", help="terraform init only")

        parser.add_argument(
            "-d",
            "--directory",
            required=True,
            help="path to terraform working directory",
        )

        args = parser.parse_args()

        mgr = cls(args.directory)

        try:
            if args.command == "apply":
                mgr.apply(args.workspace)
            elif args.command == "destroy":
                mgr.destroy(args.workspaces)
            elif args.command == "init":
                mgr._run("init", "-input=false", "-upgrade")
        except RuntimeError as exc:
            logging.error("✗ %s", exc)
            sys.exit(1)


# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    ClusterManager.cli()

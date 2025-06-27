# cluster_manager.py
#
# Terraform stack helper for CI/CD pipelines.
# Operates on the directory specified via the CLUSTER_DIR environment
# variable (defaults to the current working directory).
#
# The behaviour is driven exclusively by two environment variables:
#
#   ACTION   – one of “apply”, “destroy”, or “init” (default: “init”)
#   CLUSTERS – whitespace/comma-separated list of workspaces (required for
#              “apply” and “destroy”; ignored for “init”)
#
# Example:
#
#   export ACTION=destroy
#   export CLUSTERS="prod staging"
#   python cluster_manager.py
#
from __future__ import annotations

import argparse
import logging
import os
import subprocess
import sys
from pathlib import Path

# Local project exceptions -----------------------------------------------------
try:
    from common.exceptions import ParameterValidationError  # type: ignore
except Exception:  # pragma: no cover
    # Fallback if the shared exceptions module is not available
    class ParameterValidationError(Exception):  # noqa: D401,E501
        """Raised on invalid CLI or env parameters."""


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(levelname)-8s %(message)s",
)


class ClusterManager:
    """
    Operates a Terraform stack located in *working_directory*.

    All Terraform commands are isolated with the `-chdir=` flag so the script
    can be invoked from any path (e.g. CodeBuild, GitHub Actions, local shell).
    """

    # ───────────────────────────────────────────
    # Construction
    # ───────────────────────────────────────────
    def __init__(self, working_directory: str | Path) -> None:
        self.wd = Path(working_directory).resolve()
        if not self.wd.is_dir():
            raise ParameterValidationError(f"working directory '{self.wd}' not found")

        # `terraform -chdir=<path>` keeps the CWD of the parent process intact
        self._chdir = f"-chdir={self.wd}"
        logging.debug("Terraform chdir flag: %s", self._chdir)

    # ───────────────────────────────────────────
    # Internal helpers
    # ───────────────────────────────────────────
    def _run(self, *args: str) -> None:
        """
        Run *terraform <args>* and raise when the command exits non-zero.
        """
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s", " ".join(cmd))

        result = subprocess.run(cmd, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"terraform {args[0]} failed (exit {result.returncode})")

    def _try(self, *args: str) -> bool:
        """
        Same as `_run()` but return *True*/*False* instead of raising.
        """
        cmd = ["terraform", self._chdir, *args]
        logging.debug("$ %s (try)", " ".join(cmd))

        result = subprocess.run(cmd, text=True)
        return result.returncode == 0

    # ───────────────────────────────────────────
    # Workspace helpers
    # ───────────────────────────────────────────
    def _workspace_select(
            self,
            ws: str,
            *,
            create_if_missing: bool = False,
    ) -> None:
        """
        Select an existing workspace.

        If *create_if_missing* is *True* the workspace is created automatically.
        Otherwise the method raises – this prevents destructive operations from
        running in a freshly created, empty workspace.
        """
        if create_if_missing:
            self._run("workspace", "select", "-or-create", ws)
            return

        if not self._try("workspace", "select", ws):
            raise RuntimeError(f"workspace '{ws}' does not exist")

    # ───────────────────────────────────────────
    # Public operations
    # ───────────────────────────────────────────
    def apply(self, ws: str) -> None:
        """
        Initialise the backend, then run `terraform apply` in workspace *ws*.
        """
        logging.info("Applying stack in %s (workspace: %s)", self.wd, ws)
        self._run("init", "-input=false", "-upgrade")
        self._workspace_select(ws, create_if_missing=True)
        self._run("apply", "-auto-approve")

    def destroy(self, workspaces: list[str]) -> None:
        """
        Destroy the stack for every workspace in *workspaces*.

        The backend is initialised first so Terraform can list/select remote
        workspaces even when invoked from a fresh directory (e.g. CI runner).
        """
        logging.info("Destroying stack in %s", self.wd)
        self._run("init", "-input=false", "-upgrade")

        for ws in workspaces:
            logging.info("→ Workspace '%s'", ws)
            self._workspace_select(ws, create_if_missing=False)
            self._run("destroy", "-auto-approve")

    # ───────────────────────────────────────────
    # Optional CLI wrapper (handy for local testing)
    # ───────────────────────────────────────────
    @classmethod
    def cli(cls) -> None:
        """
        A thin argparse wrapper kept for local development convenience.

        For CI/CD the script is usually driven purely through the ACTION /
        CLUSTERS environment variables – see `main()` below.
        """
        parser = argparse.ArgumentParser(description="Terraform cluster manager")
        sub = parser.add_subparsers(dest="command")

        p_apply = sub.add_parser("apply", help="terraform apply")
        p_apply.add_argument("workspace", help="workspace to apply")

        p_destroy = sub.add_parser("destroy", help="terraform destroy")
        p_destroy.add_argument("workspaces", nargs="+", help="workspace(s) to destroy")

        sub.add_parser("init", help="terraform init only")

        parser.add_argument(
            "-d",
            "--directory",
            default=".",
            help="path to terraform working directory (default: .)",
        )

        args = parser.parse_args()
        mgr = cls(args.directory)

        try:
            if args.command is None or args.command == "init":
                mgr._run("init", "-input=false", "-upgrade")

            elif args.command == "apply":
                mgr.apply(args.workspace)

            elif args.command == "destroy":
                mgr.destroy(args.workspaces)

        except RuntimeError as exc:
            logging.error("✗ %s", exc)
            sys.exit(1)


# ─────────────────────────────────────────────────────────────────────────────
# Entry-point for CI/CD pipelines – driven by ENV variables
# ─────────────────────────────────────────────────────────────────────────────
def _env_action() -> str:
    value = os.getenv("ACTION", os.getenv("action", "init")).strip().lower()
    allowed = {"init", "apply", "destroy"}
    if value not in allowed:
        raise ParameterValidationError(
            f"ACTION must be one of {', '.join(sorted(allowed))!r}; got {value!r}"
        )
    return value


def _env_clusters() -> list[str]:
    raw = os.getenv("CLUSTERS", os.getenv("clusters", "")).strip()
    if not raw:
        return []
    # Accept comma or whitespace as separator
    parts = [p.strip() for p in raw.replace(",", " ").split() if p.strip()]
    return parts


def main() -> None:
    action = _env_action()
    clusters = _env_clusters()
    wd = Path(os.getenv("CLUSTER_DIR", ".")).resolve()

    mgr = ClusterManager(wd)

    try:
        if action == "init":
            logging.info("Initialising backend in %s", wd)
            mgr._run("init", "-input=false", "-upgrade")

        elif action == "apply":
            if len(clusters) != 1:
                raise ParameterValidationError(
                    "CLUSTERS must contain exactly one workspace for ACTION=apply"
                )
            mgr.apply(clusters[0])

        elif action == "destroy":
            if not clusters:
                raise ParameterValidationError(
                    "CLUSTERS must list at least one workspace for ACTION=destroy"
                )
            mgr.destroy(clusters)

    except RuntimeError as exc:
        logging.error("✗ %s", exc)
        sys.exit(1)


if __name__ == "__main__":
    # Prefer env-driven execution; fall back to CLI when no ACTION is set
    if "ACTION" in os.environ or "action" in os.environ:
        main()
    else:
        ClusterManager.cli()

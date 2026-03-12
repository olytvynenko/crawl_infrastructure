"""
Configuration hierarchy and AWS Parameter Store helpers.

1. Environment variables: ACTION, LEVEL, CLUSTERS
2. Parameter Store: /crawl/clusters (StringList)
"""
from __future__ import annotations

import json
import logging
import os
from enum import Enum
from functools import lru_cache
from typing import List

import boto3

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Exceptions and enums
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Parameter Store
# ---------------------------------------------------------------------------

_ssm = boto3.client("ssm")


@lru_cache(maxsize=32)
def get_param(name: str) -> str | None:
    """Return parameter value or None if missing."""
    for candidate in (f"/crawl/{name}", name):
        try:
            res = _ssm.get_parameter(Name=candidate, WithDecryption=True)
            return res["Parameter"]["Value"]
        except _ssm.exceptions.ParameterNotFound:
            continue
    return None


def clusters_from_config() -> List[str]:
    """
    Resolve cluster list:
      1. Parameter Store (/crawl/clusters) – StringList
      2. Fallback to $CLUSTERS env var
    """
    raw = get_param("clusters") or os.getenv("CLUSTERS")
    if not raw:
        raise ParameterValidationError(
            "cluster list not found: set /crawl/clusters (StringList) "
            "or CLUSTERS env var"
        )
    return [c.strip() for c in raw.split(",") if c.strip()]


# ---------------------------------------------------------------------------
# Tag keys and orphan ENI cleanup
# ---------------------------------------------------------------------------


def get_tag_keys() -> List[str]:
    """Return tag keys that identify cluster resources (for orphan ENI cleanup)."""
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


def delete_orphan_enis(tag_keys: List[str]) -> None:
    """Remove detached ENIs that still carry one of tag_keys (status=available)."""
    if not tag_keys:
        logger.info("No tag keys provided – skipping orphan-ENI cleanup")
        return

    ec2 = boto3.client("ec2")
    filters = [
        {"Name": "status", "Values": ["available"]},
        {"Name": "tag-key", "Values": tag_keys},
    ]
    paginator = ec2.get_paginator("describe_network_interfaces")
    orphan_ids: List[str] = []
    for page in paginator.paginate(Filters=filters):
        orphan_ids.extend(eni["NetworkInterfaceId"] for eni in page["NetworkInterfaces"])

    if not orphan_ids:
        logger.info("No orphan ENIs found")
        return

    logger.info("Deleting %d orphan ENIs: %s", len(orphan_ids), orphan_ids)
    for eni_id in orphan_ids:
        try:
            ec2.delete_network_interface(NetworkInterfaceId=eni_id)
            logger.debug("Deleted ENI %s", eni_id)
        except Exception as exc:
            logger.warning("Failed to delete ENI %s: %s", eni_id, exc)

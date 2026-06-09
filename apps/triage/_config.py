"""
_config.py

Layout-agnostic config resolution shared by the triage modules.

The package runs in two layouts from the same source:
  - in-repo as `apps.triage` (config at the repo root `config/config.yml`)
  - standalone as `triage` (config in a sibling `configs/config.yml`,
    e.g. a Docker image or extracted folder)

Resolution order:
  1. $TRIAGE_CONFIG — explicit path override (used by the Docker image).
  2. Walk up from this file's location; the first parent containing
     `config/config.yml` OR `configs/config.yml` wins.

This replaces the old `Path(__file__).resolve().parents[2]` hardcoding,
which assumed the package sat exactly two levels below the config dir.
"""

import os
from functools import lru_cache
from pathlib import Path

_CONFIG_DIRS = ("config", "configs")


@lru_cache(maxsize=1)
def find_config_file() -> Path:
    """Absolute path to config.yml. Raises FileNotFoundError if none found."""
    override = os.environ.get("TRIAGE_CONFIG")
    if override:
        return Path(override).expanduser().resolve()

    here = Path(__file__).resolve()
    for parent in here.parents:
        for d in _CONFIG_DIRS:
            candidate = parent / d / "config.yml"
            if candidate.exists():
                return candidate

    raise FileNotFoundError(
        "config.yml not found. Looked for config/config.yml or "
        "configs/config.yml walking up from this package. "
        "Set $TRIAGE_CONFIG to point at it explicitly."
    )


def config_dir() -> Path:
    """Directory holding config.yml — also where module_component_map.csv lives."""
    return find_config_file().parent

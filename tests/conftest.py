"""Shared helpers for loading securetty scripts as modules in tests."""

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GOLDEN_DIR = Path(__file__).resolve().parent / "golden"


def load_script(relative_path: str, module_name: str):
    """Load a standalone script by path and return it as a module."""
    spec = importlib.util.spec_from_file_location(
        module_name,
        REPO_ROOT / relative_path,
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {relative_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def golden(name: str) -> str:
    """Return the contents of a golden output file."""
    return (GOLDEN_DIR / name).read_text(encoding="utf-8")

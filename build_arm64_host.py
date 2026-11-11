#!/usr/bin/env python3
"""Compatibility entry point for the Swift host build."""
import os
from pathlib import Path

root = Path(__file__).resolve().parent
os.execv("/bin/zsh", ["zsh", str(root / "build.sh"), "--host-only"])

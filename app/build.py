"""Compatibility entry point for the native Swift application build."""
import os
from pathlib import Path

root = Path(__file__).resolve().parent.parent
os.execv("/bin/zsh", ["zsh", str(root / "build.sh")])

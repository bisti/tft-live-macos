#!/usr/bin/env python3
"""Compatibility entry point for the native Swift launcher."""
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parent
executable = root / "TFT Live.app/Contents/MacOS/TFTLiveCLI"
if not executable.is_file():
    executable = root / ".build/arm64-apple-macosx/release/TFTLiveCLI"
if not executable.is_file():
    sys.exit("Build the native launcher with ./build.sh, then run it again.")
os.chdir(root)
os.execv(str(executable), [str(executable), *sys.argv[1:]])

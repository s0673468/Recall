#!/usr/bin/env python3
"""Render Recall's web icons from the shared cross-platform brand master."""
from __future__ import annotations

import sys
from pathlib import Path

SHARED_TOOL = Path(__file__).resolve().parents[3] / "tool"
sys.path.insert(0, str(SHARED_TOOL))

from render_web_icon_sets import render_app  # noqa: E402


if __name__ == "__main__":
    render_app("recall")

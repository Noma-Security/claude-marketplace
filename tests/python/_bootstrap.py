"""Shared test bootstrap: put the generic package and the guardrails plugin
scripts on sys.path so every test imports the SAME repo-root copies (the
drift check guarantees the vendored copies are identical, so testing the
source is sufficient).
"""

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

for _p in (os.path.join(REPO_ROOT, "common"),
           os.path.join(REPO_ROOT, "guardrails", "scripts")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

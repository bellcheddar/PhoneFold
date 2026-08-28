#!/bin/bash
# setup_env.sh — create Tools/.venv on Homebrew python3.12 and install the pinned Phase 0 stack.
# torch has no python3.14 wheels, which is why 3.12 is pinned rather than the system default.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/Tools"
PY=/opt/homebrew/bin/python3.12
[[ -x "$PY" ]] || { echo "python3.12 not found at $PY" >&2; exit 1; }
[[ -d .venv ]] || "$PY" -m venv .venv
./.venv/bin/pip install --quiet --upgrade pip
./.venv/bin/pip install -r requirements.txt
./.venv/bin/python -c "import torch, transformers, coremltools, biotite; \
print('torch', torch.__version__, 'mps', torch.backends.mps.is_available()); \
print('transformers', transformers.__version__); print('coremltools', coremltools.__version__); \
print('biotite', biotite.__version__)"

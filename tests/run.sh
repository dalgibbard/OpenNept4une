#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1

bash "$REPO_ROOT/tests/test_repo_utils.sh"
bash "$REPO_ROOT/tests/test_opennept4une.sh"
bash "$REPO_ROOT/tests/test_board_hardware_setup.sh"
bash "$REPO_ROOT/tests/test_rpi_mcu_install.sh"
bash "$REPO_ROOT/tests/test_set_printer_model.sh"
python3 -m unittest discover -s "$REPO_ROOT/tests" -p 'test_*.py' -v

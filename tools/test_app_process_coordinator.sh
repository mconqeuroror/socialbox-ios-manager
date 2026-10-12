#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rbx-app-process-coordinator.XXXXXX")
trap 'rm -f "$temporary/test"; rmdir "$temporary"' EXIT
sanitizers=(-Werror=return-type)
startup_budget=$(python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
text = (Path(sys.argv[1]) / 'daemon/main.m').read_text()
match = re.search(r'BOOL startupProcessesClosed = \[sProc killAllAndWait:([^\]]+)\];', text)
assert match, 'startup stop budget must be bound to the actual dispatcher'
print(match[1])
PY
)
if [[ "${RBX_TEST_THREAD_SANITIZER:-0}" == "1" ]]; then sanitizers+=(-fsanitize=thread); fi
xcrun clang -fobjc-arc -fblocks -Wno-nullability-completeness \
    -DRBX_APP_PROCESS_COORDINATOR_TESTING=1 -I"$ROOT/shared" -I"$ROOT/daemon" \
    "-DRBX_STARTUP_STOP_BUDGET=$startup_budget" \
    "${sanitizers[@]}" -framework Foundation "$ROOT/tools/test_app_process_coordinator.m" "$ROOT/shared/RBXProcessIdentity.m" -o "$temporary/test"
"$temporary/test"

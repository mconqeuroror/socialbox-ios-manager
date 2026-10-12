#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
journal_test_build=$(mktemp -d "${TMPDIR:-/tmp}/socialbox-native-journal-test.XXXXXX")
trap 'rm -rf "$journal_test_build"' EXIT
journal_flags=(-fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations)
xcrun clang "${journal_flags[@]}" -DLBX_NATIVE_ISOLATION_JOURNAL_TESTING=1 -framework Foundation \
  lucid/Switching/LBXNativeIsolationJournal.m tools/test_native_isolation_journal.m -o "$journal_test_build/test"
"$journal_test_build/test"
for journal_arch in arm64 arm64e; do
  xcrun --sdk iphoneos clang -target "$journal_arch-apple-ios15.0" "${journal_flags[@]}" \
    -c lucid/Switching/LBXNativeIsolationJournal.m -o "$journal_test_build/journal-$journal_arch.o"
done
python3 - "$journal_test_build" <<'PY'
from pathlib import Path
import sys
for binary in Path(sys.argv[1]).glob('*.o'):
    data = binary.read_bytes()
    assert b'testOpenDirectory:' not in data and b'testSetFault:' not in data, 'fixture API in production object'
print('PASS: strict arm64/arm64e journal compilation; fixture APIs absent')
PY

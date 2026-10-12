#!/usr/bin/env python3
"""Run the real update evaluator/service with a local NSURLProtocol transport."""
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='socialbox-update-test-') as directory:
    executable = Path(directory) / 'UpdateFixture'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                    '-DSB_UPDATE_FOUNDATION_ONLY=1', '-DSB_UPDATE_TESTING=1', '-framework', 'Foundation',
                    '-I' + str(HERE.parent), str(HERE.parent / 'SBUpdateService.m'),
                    str(HERE / 'update_service_fixture.m'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)

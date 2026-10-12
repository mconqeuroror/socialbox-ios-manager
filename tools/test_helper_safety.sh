#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
run_dir=$(mktemp -d -t socialbox-helper)
trap 'rm -rf "$run_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
    tools/test_helper_safety_protocol.m lucid/HelperSafety/LBXDrainProtocol.m \
    lucid/Switching/LBXManagedApplications.m -o "$run_dir/protocol"
"$run_dir/protocol"
python3 tools/test_managed_applications.py
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
    tools/test_helper_safety_client.m lucid/HelperSafety/LBXDrainProtocol.m \
    lucid/Switching/LBXManagedApplications.m -o "$run_dir/client"
"$run_dir/client"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    tools/test_helper_safety_hook.m lucid/Switching/LBXManagedApplications.m -o "$run_dir/hook"
"$run_dir/hook"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    tools/test_helper_safety_peer.m lucid/HelperSafety/LBXDrainProtocol.m lucid/Switching/LBXManagedApplications.m \
    lucid/Switching/LBXProcessDrain.m lucid/Switching/LBXDarwinDrainBackend.m shared/RBXProcessIdentity.m -o "$run_dir/peer"
"$run_dir/peer"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    tools/test_helper_caller_file.m -o "$run_dir/caller-file"
"$run_dir/caller-file"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    tools/test_app_switch_safety.m tools/test_app_switch_callsite.S lucid/HelperSafety/LBXGlobalMetadata.m \
    lucid/HelperSafety/LBXGlobalMetadataHook.m -o "$run_dir/app-switch"
"$run_dir/app-switch"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
    tools/test_global_metadata.m -o "$run_dir/metadata"
"$run_dir/metadata"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation \
    tools/test_global_metadata_hook.m -o "$run_dir/metadata-hook"
"$run_dir/metadata-hook"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RBX_PACKAGE_SCHEME="${RBX_PACKAGE_SCHEME:-rootless}"
case "$RBX_PACKAGE_SCHEME" in
  rootless) PACKAGE_ARCH=iphoneos-arm64; PACKAGE_SCHEME=rootless ;;
  rootful) PACKAGE_ARCH=iphoneos-arm; PACKAGE_SCHEME= ;;
  *) echo "RBX_PACKAGE_SCHEME must be rootless or rootful" >&2; exit 1 ;;
esac
: "${THEOS:?Set THEOS to your Theos installation}"
: "${LICENSE_PUBLIC_KEY_FILE:?Set LICENSE_PUBLIC_KEY_FILE to your deployment public PEM key (see scripts/license-key.py)}"

for tool in make xcodebuild xcodegen python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
LDID="$(command -v "${LDID:-ldid}")" || {
  echo "Missing Procursus ldid. Install ldid-procursus or set LDID to its executable." >&2
  exit 1
}

NE_DIR="$ROOT/network-extension"
BUILD_DIR="$ROOT/build/network-extension"
PROJECT="$BUILD_DIR/RedditBoxFirewall.xcodeproj"
ARCHIVE="$BUILD_DIR/RedditBoxFirewall.xcarchive"
LICENSE_PIN_HEADER="$ROOT/build/generated/RBXLicensePublicKey.h"
VERSION=$(python3 "$ROOT/scripts/build-version.py" --root "$ROOT")
VARIANT_INPUTS=$(python3 "$ROOT/scripts/package_variant.py" "$RBX_PACKAGE_SCHEME")
python3 "$ROOT/tools/test_build_version.py"
python3 "$ROOT/tools/test_package_variants.py"
python3 "$ROOT/tools/test_apt_release.py"
python3 "$ROOT/scripts/license-key.py" pin --public-key "$LICENSE_PUBLIC_KEY_FILE" --output "$LICENSE_PIN_HEADER"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
python3 "$ROOT/tools/test_facebook_binary_audit.py"
bash "$ROOT/tools/test_app_bundle_policy.sh"
bash "$ROOT/tools/test_app_runtime.sh"
python3 "$ROOT/tools/test_facebook_user_agent.py"
python3 "$ROOT/tools/test_facebook_user_agent_hooks.py"
bash "$ROOT/tools/test_facebook_storage_policy.sh"
bash "$ROOT/tools/test_facebook_private_group_store.sh"
python3 "$ROOT/tools/test_facebook_storage_hooks.py"
python3 "$ROOT/tools/test_app_profile.py"
python3 "$ROOT/tools/test_clone_profile_ownership.py"
bash "$ROOT/tools/test_app_registry.sh"
bash "$ROOT/tools/test_workspace_selection.sh"
python3 "$ROOT/tools/test_workspace_dispatch.py"
bash "$ROOT/tools/test_app_keychain_policy.sh"
bash "$ROOT/tools/test_app_keychain_hooks.sh"
bash "$ROOT/tools/test_app_keychain_entitlements.sh"
bash "$ROOT/tools/test_process_identity.sh"
bash "$ROOT/tools/test_app_process.sh"
bash "$ROOT/tools/test_app_process_coordinator.sh"
python3 "$ROOT/tools/test_app_source.py"
bash "$ROOT/tools/test_app_mdm.sh"
bash "$ROOT/tools/test_app_scope.sh"
python3 "$ROOT/tools/test_launcher_multiapp.py"
python3 "$ROOT/tools/test_workspace_presentation.py"
python3 "$ROOT/tools/test_settings_presentation.py"
python3 "$ROOT/tools/test_apt_metadata_refresh.py"
python3 "$ROOT/tools/test_clone_architecture.py"
python3 "$ROOT/tools/test_identity_editor.py"
bash "$ROOT/tools/test_location_screen.sh"
python3 "$ROOT/tools/test_clone_visibility_metadata.py"
python3 "$ROOT/tools/test_installer_evidence.py"
python3 "$ROOT/tools/test_app_install_recovery.py"
python3 "$ROOT/tools/test_app_removal_identity.py"
python3 "$ROOT/tools/test_app_deletion_flow.py"
python3 "$ROOT/tools/test_app_deletion_targets.py"
python3 "$ROOT/tools/test_app_deletion_closure.py"
python3 "$ROOT/tools/test_app_launch_flow.py"
python3 "$ROOT/tools/test_app_gate_control.py"
python3 "$ROOT/tools/test_clone_gate_writer.py"
python3 "$ROOT/tools/test_app_gate_readiness.py"
python3 "$ROOT/tools/test_app_global_recovery.py"
python3 "$ROOT/tools/test_app_maintenance_closure.py"
python3 "$ROOT/tools/test_app_replacement_backend.py"
python3 "$ROOT/tools/test_identity_manual_inputs.py"
python3 "$ROOT/tools/test_automatic_identity.py"
python3 "$ROOT/tools/test_creation_prepare.py"
python3 "$ROOT/tools/test_creation_dispatch.py"
python3 "$ROOT/tools/test_creation_source_binding.py"
bash "$ROOT/tools/test_creation_draft_store.sh"
python3 "$ROOT/tools/test_passcode_removal.py"
sh "$ROOT/tools/test_passcode_store.sh"
python3 "$ROOT/tools/test_identity_user_agent.py"
python3 "$ROOT/tools/test_app_version_settings.py"
python3 "$ROOT/tools/test_creation_defaults.py"
python3 "$ROOT/tools/test_device_catalog_data.py"
python3 "$ROOT/tools/test_device_version_hook.py"
python3 "$ROOT/tools/test_sensor_startup.py"
python3 "$ROOT/tools/test_clone_support_directory.py"
bash "$ROOT/tools/test_storage_gate.sh"
bash "$ROOT/tools/test_storage_access.sh"
bash "$ROOT/tools/test_staged_executable.sh"
python3 "$ROOT/tools/test_identity_choices.py"
python3 "$ROOT/tools/test_launcher_architecture.py"
python3 "$ROOT/tests/test_replacement_architecture.py"
bash "$ROOT/tools/test_firewall_policy.sh"
bash "$ROOT/tools/test_pf_policy_plan.sh"
bash "$ROOT/tools/test_pf_kernel_policy.sh"
bash "$ROOT/tools/test_request_queue.sh"
bash "$ROOT/tools/test_secure_config.sh"
bash "$ROOT/tools/test_identity_draft_store.sh"
bash "$ROOT/tools/test_cloud_vault_store.sh"
python3 "$ROOT/tools/test_cloud_vault_bridge.py"
python3 "$ROOT/tools/test_cloud_app_admission.py"
python3 "$ROOT/tools/test_cloud_assignment_closure.py"
python3 "$ROOT/tools/test_preinstall.py"
python3 "$ROOT/tools/test_postinstall.py"
python3 "$ROOT/tools/test_macho_probe.py"
python3 "$ROOT/tools/test_request_budgets.py"
bash "$ROOT/tools/test_proxy_library.sh"
bash "$ROOT/tools/test_proxy_import.sh"
python3 "$ROOT/tools/test_proxy_configuration.py"
python3 "$ROOT/tools/test_proxy_redirect_policy.py"
sh "$ROOT/tools/test_proxy_region.sh"
python3 "$ROOT/tools/test_proxy_region_transport.py"
bash "$ROOT/tools/test_rotation_secrets.sh"
bash "$ROOT/tools/test_backup_snapshot.sh"
python3 "$ROOT/tools/test_backup_identity.py"
python3 "$ROOT/tools/test_app_backup_flow.py"
python3 "$ROOT/tools/test_app_backup_transaction.py"
python3 "$ROOT/tools/test_backup_restore_cleanup.py"
python3 "$ROOT/tools/test_backup_archive.py"
python3 "$ROOT/tools/test_identity_freeze.py"
python3 "$ROOT/tools/test_smoke_log_order.py"
python3 "$ROOT/tools/test_sign_firewall_app.py"
bash "$ROOT/tools/test_keychain_cleaner.sh"
bash "$ROOT/tools/test_keychain_sync.sh"
bash "$ROOT/tools/test_clone_acceptance.sh"
bash "$ROOT/tools/test_isolation_sentinel.sh"
bash "$ROOT/tools/test_sentinel_controller.sh"
bash "$ROOT/tools/test_launch_safety.sh"
python3 "$ROOT/tools/test_proxy_route_transport.py"
bash "$ROOT/tools/test_acceptance_checks.sh"
bash "$ROOT/tools/test_operator_wording.sh"
bash "$ROOT/tools/test_wizard_draft.sh"
python3 "$ROOT/tools/test_device_acceptance_ssh.py"
python3 "$ROOT/tools/test_device_acceptance_canaries.py"
bash "$ROOT/tools/test_deletion_journal.sh"
bash "$ROOT/tools/test_profile_metadata.sh"
python3 "$ROOT/tools/test_profile_rename.py"
bash "$ROOT/tests/test_replacement.sh"
python3 "$ROOT/tools/test_profile_metadata.py"
python3 "$ROOT/tools/test_account_status_browser.py"
python3 "$ROOT/tools/test_license_key.py"
python3 "$ROOT/tools/test_license_screen.py"
python3 "$ROOT/tools/test_license_presentation.py"
bash "$ROOT/tools/test_license_presentation.sh"
bash "$ROOT/tests/test_license_token.sh"
python3 "$ROOT/tests/test_license_architecture.py"
python3 "$ROOT/tools/test_license_dispatch.py"
bash "$ROOT/tests/test_data_schema.sh"
python3 "$ROOT/tests/test_data_schema_architecture.py"
python3 "$ROOT/tools/test_update_startup.py"
bash "$ROOT/tools/test_device_catalog.sh"
bash "$ROOT/tools/test_fingerprint_registry.sh"
bash "$ROOT/tools/test_operation_context.sh"
bash "$ROOT/tools/test_memory_budget.sh"
bash "$ROOT/tools/test_request_deadlines.sh"
bash "$ROOT/tools/test_bounded_process.sh"
bash "$ROOT/tools/test_service_lifetime.sh"
bash "$ROOT/tools/test_socket_guard.sh"
bash "$ROOT/tools/test_exception_port_guard.sh"
bash "$ROOT/tools/test_hook_readiness.sh"
python3 "$ROOT/tools/test_optional_ios_hooks.py"
bash "$ROOT/tools/test_http_proxy.sh"
bash "$ROOT/tools/test_reddit_payload.sh"
python3 "$ROOT/tools/test_leak_audit.py"
python3 "$ROOT/tools/test_leak_surface.py"
python3 "$ROOT/tools/check_pasteboard_api.py"
# Keep generated plist settings and source paths relative to the same directory.
cp -R "$NE_DIR/FirewallHost" "$NE_DIR/PacketTunnel" "$BUILD_DIR/"
cp "$NE_DIR/project.yml" "$BUILD_DIR/project.yml"
xcodegen generate --spec "$BUILD_DIR/project.yml" --project "$BUILD_DIR"
test -f "$PROJECT/project.pbxproj" || { echo "XcodeGen produced no project: $PROJECT" >&2; exit 1; }
xcodebuild archive \
  -project "$PROJECT" \
  -scheme RedditBoxFirewall \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE=Manual

FIREWALL_APP="$ARCHIVE/Products/Applications/RedditBoxFirewall.app"
test -d "$FIREWALL_APP" || { echo "NetworkExtension archive produced no app" >&2; exit 1; }
python3 "$ROOT/scripts/sign-firewall-app.py" "$FIREWALL_APP" --ldid "$LDID"

chmod 755 "$ROOT/layout/DEBIAN/preinst" "$ROOT/layout/DEBIAN/postinst" "$ROOT/layout/DEBIAN/prerm" "$ROOT/layout/DEBIAN/postrm"
make -C "$ROOT" clean package FINALPACKAGE=1 RBX_FIREWALL_APP="$FIREWALL_APP" \
  RBX_PACKAGE_SCHEME="$RBX_PACKAGE_SCHEME" THEOS_PACKAGE_SCHEME="$PACKAGE_SCHEME" \
  THEOS_PACKAGE_ARCH="$PACKAGE_ARCH" THEOS_LAYOUT_DIR="$VARIANT_INPUTS/layout" \
  RBX_VARIANT_INPUTS="$VARIANT_INPUTS" \
  PACKAGE_VERSION="$VERSION" THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip \
  RBX_RELEASE_METADATA="$ROOT/build/generated/release.json" \
  RedditBox_RESOURCE_DIRS="$ROOT/build/generated/launcher-resources" \
  RBX_LICENSE_PIN_HEADER="$LICENSE_PIN_HEADER" \
  TARGET_CODESIGN="$LDID" TARGET_CODESIGN_FLAGS=-S

echo
echo "Build complete ($RBX_PACKAGE_SCHEME). Install this matching package:"
test -f "$ROOT/packages/com.redditbox_${VERSION}_${PACKAGE_ARCH}.deb"
echo "$ROOT/packages/com.redditbox_${VERSION}_${PACKAGE_ARCH}.deb"

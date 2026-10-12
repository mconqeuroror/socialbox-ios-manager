"""Portable schema boundary checks; native tests exercise the actual Objective-C engine."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
read = lambda name: (ROOT / name).read_text(encoding="utf-8")
schema = read("shared/RBXDataSchema.h")
central = read("daemon/RBXCentralStore.m")
profile = read("daemon/RBXProfileIO.m")
migration = read("daemon/RBXDataMigration.m")
assert "RBX_STORE_SCHEMA_VERSION 2" in schema and "RBX_PROFILE_SCHEMA_VERSION 2" in schema
assert "CFBooleanGetTypeID" in schema and "version > current" in schema
assert "O_EXCL | O_NOFOLLOW" in schema and "fsync(fd)" in schema
assert "rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation)" in schema
assert "expected && ![old isEqual:expected]" in schema
assert "RBXSchemaWriteJSONCompared(doc, self.class.storePath" in central
assert "[doc setObject:@1" not in central and "dictionaryWithError:" in central
assert "if (missing) return [self _defaultDocument]" in central
assert "RBXSchemaValidate(profile, RBXDataProfile" in profile
assert "RBXSchemaWriteJSONCompared(profile" in profile
body = migration[migration.index("+ (BOOL)preflightAndMigrateWithError:"):]
assert body.index("[self _preflight:error]") < body.index("for (NSDictionary *record") < body.index("_publishDocument:")
for field in ("com.redditbox.store.json", "com.redditbox.profiles", "com.redditbox.deleted-containers.plist", "deletions", "transactions", "uninstall-evidence"):
    assert field in migration
assert "removeItem" not in migration and "generateProfile" not in migration
for name in ("prefs/RBXDashboardController.m", "prefs/RBXContainersListController.m",
             "tweak/AppAttest/RBXAppAttestHooks.xm", "tweak/LeakDetection/RBXRequestAudit.xm",
             "tweak/Container/RBXContainerManager.xm"):
    source = read(name)
    assert '#import "RBXDataSchema.h"' in source, name
    assert "RBXSchemaWriteJSON" in source, name
print("PASS: shared schema boundaries and complete preflight ordering")

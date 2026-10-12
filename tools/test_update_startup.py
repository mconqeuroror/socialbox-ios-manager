"""Startup/mutation integration contracts; native fixtures test the actual engines."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
read = lambda p: (ROOT / p).read_text(encoding="utf-8")
main = read("daemon/main.m")
startup = main[main.index('NSDictionary *startup = @{@"requestId":'):]
preflight = startup.index("preflightAndMigrateWithError:")
for operation in ("migrateProfilesWithError:", "migrateAppClonesWithError:", "recordAppliedUpdate(",
                  "[[RBXCloudSync sharedSync] start]", "[sVersionMonitor startMonitoring]",
                  "[[RBXLeakMonitor sharedMonitor] start]", "refreshAndCheck"):
    assert startup.index(operation) > preflight, operation
assert startup.index("sDataReady = YES") > preflight
assert "!dataReady() && !internalStartup && !context.inspectionOnly" in main
assert "inspectionOnly && (!dataReady() ||" in main
assert "if (!dataReady()) return" in main[main.index("static void scheduleLicenseCheck"):]
assert "containerIdsWithError:error" in main[main.index("static BOOL recordAppliedUpdate"):]
assert "containers loaded: %lu" in main and "lastAppliedUpdate" in main
for name in ("daemon/RBXContainerRegistry.m", "daemon/RBXCloudSync.m", "daemon/RBXProxyManager.m", "daemon/RBXCloneManager.m"):
    assert "[RBXProfileIO writeProfile:" in read(name), name
registry = read("daemon/RBXContainerRegistry.m")
assert "link(temporary.fileSystemRepresentation, path.fileSystemRepresentation)" in registry
assert "RBXRestoreDeletionEvidence(restoreData, profilePath)" in registry
assert "RBXSchemaReadVersion(schemaEvidence" in registry
assert "RBX_PROFILE_SCHEMA_VERSION" in read("daemon/RBXProfileGenerator.m")
print("PASS: update startup ordering, inspection reachability and guarded profile publications")

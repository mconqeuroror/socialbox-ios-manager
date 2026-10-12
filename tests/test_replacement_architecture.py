"""Portable contracts around the actual native replacement implementation.

Native injected failure cases run on macOS with tests/test_replacement.sh.
These source checks cover cross-component safety integration, not runtime iOS.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
replacement = (root / "daemon/RBXReplacement.m").read_text(encoding="utf-8")
registry = (root / "daemon/RBXContainerRegistry.m").read_text(encoding="utf-8")
process = (root / "daemon/RBXProcessController.m").read_text(encoding="utf-8")
engine = replacement.split("#ifndef RBX_REPLACEMENT_TESTING")[0]
assert engine.index('persistJournal:stored') < engine.index('createCandidateForJournal:journal')
assert engine.index('rotateCandidateForJournal:journal') < engine.index('RBXReplacementAdvance(journal, @"rotated"')
assert engine.index('RBXReplacementAdvance(journal, @"deleting"') < engine.index('deleteOriginalForJournal:journal')
assert engine.index('deleteOriginalForJournal:journal') < engine.index('RBXReplacementAdvance(journal, @"committed"')
closure = replacement.split('- (BOOL)establishClosureForJournal:')[1].split('- (BOOL)createCandidateForJournal:')[0]
assert closure.index('targetStopped:oldID') < closure.index('closeTrafficWithReason:')
assert closure.index('closeTrafficWithReason:') < closure.index('killAllAndWait:') < closure.index('waitForMaintenanceClosure:')
assert 'syncProfileInventoryWithContext:self.context' in replacement
assert 'syncRotationAuthForContainer:identifier context:self.context' in replacement
assert 'forContainer:identifier local:YES' in replacement and '@"notes": @""' in replacement
assert 'previousExitIP:previous' in replacement
assert 'launchAllowedForContainer:' in replacement
run = engine.split('NSString *RBXRunReplacement(')[1]
assert run.index('replacementAllowedForContainer:container') < run.index('journalForContainer:container')
policy = engine.split('BOOL RBXReplacementMutationAllowed(')[1].split('static BOOL RBXReplacementAdvance')[0]
assert policy.index('RBXReplacementInventoryValid(journals') < policy.index('for (NSDictionary *journal')
assert 'candidate || (original && mutation == RBXReplacementUserDelete)' in policy
main = (root / 'daemon/main.m').read_text(encoding='utf-8')
assert 'userDeletionAllowedForContainer:cid error:&actionError] ||' in main
assert main.index('userDeletionAllowedForContainer:cid') < main.index('[sRegistry deleteContainer:cid error:&actionError]')
backend_delete = replacement.split('- (BOOL)deleteOriginalForJournal:')[1].split('@end')[0]
assert '[self.registry deleteContainer:journal[@"oldId"] error:error]' in backend_delete
assert 'userDeletionAllowed' not in backend_delete  # Internal ordered recovery owns this deletion.
launcher = (root / 'launcher/RBXLauncherViewController.m').read_text(encoding='utf-8')
select = launcher.split('didSelectRowAtIndexPath:')[1].split('- (void)confirmOpenContainer:')[0]
assert '[pendingReplacement[@"newId"] isEqual:row[@"id"]]' in select
assert '[pendingReplacement[@"phase"] isEqual:@"deleting"]' in select
assert 'actionWithTitle:pendingReplacement ? @"Resume Replace" : @"Replace with new"' in select
assert 'if (!pendingReplacement)' in select
swipe = launcher.split('trailingSwipeActionsConfigurationForRowAtIndexPath:')[1].split('- (void)confirmReplaceContainer:')[0]
assert swipe.index('RBXPendingReplacementForRow(row)') < swipe.index('UIContextualAction *remove')
assert 'title:@"Resume Replace"' in swipe and 'return pending;' in swipe
confirm_delete = launcher.split('- (void)confirmDeleteContainer:(NSDictionary *)row {')[1].split('\n- (')[0]
assert confirm_delete.index('RBXPendingReplacementForRow(row)') < confirm_delete.index('UIAlertController *confirmation')
assert 'isProfileStopped:profile error:error' in replacement
inspection = process.split('- (BOOL)isProfileStopped:')[1].split('- (NSArray<NSNumber *> *)appPids:')[0]
assert 'RBXProcessPaths(error)' in inspection and 'RBXRegisteredExecutable(identifier, bundlePath, error)' in inspection
assert not re.search(r'\bkill\s*\(|killAllAndWait:|killReddit', inspection)
assert 'RBXCheckedIdentityReservations(error)' in registry
assert 'reserveIdentityForProfile:validated error:error' in registry
assert 'reserveIdentityForProfile:profile error:&failure' in registry
assert 'CC_SHA256(bytes.bytes' in registry
assert 'removeObjectForKey:@"identityReservations"' not in registry
print('PASS replacement ordering, inactivity, recovery, rotation, cloud ownership and identity reservation contracts')

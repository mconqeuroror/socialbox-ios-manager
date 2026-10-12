#import <Foundation/Foundation.h>
// In-memory synthetic root protocol only. Never linked by production selection.
// Reset begins unavailable; explicit fixture initialization is not a UI action.
void SBTestSavedSetupReset(void);
void SBTestSavedSetupInitializeRoot(void);
BOOL SBTestSavedSetupRemoveSyntheticRoot(void);
void SBTestSavedSetupSetLicenseResult(NSString *result);
void SBTestSavedSetupSetMutationBehavior(NSString *behavior);
void SBTestSavedSetupValidate(void (^completion)(NSDictionary *));
void SBTestSavedSetupCompleteDeferred(NSString *result,BOOL publish);
void SBTestSavedSetupReplayDeferred(void);
NSUInteger SBTestSavedSetupCount(NSString *operation);
NSUInteger SBTestSavedSetupValidateCount(void);
NSDictionary *SBTestSavedSetupLastCandidate(void);
NSDictionary *SBTestSavedSetupLastExpected(void);
NSDictionary *SBTestSavedSetupLastStageArguments(void);
NSDictionary *SBTestSavedSetupRecordSnapshot(void);
NSDictionary *SBTestSavedSetupRootState(void);

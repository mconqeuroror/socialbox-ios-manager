#import <Foundation/Foundation.h>
@class UIViewController;
@class UILabel;
typedef NS_ENUM(NSUInteger, LBXDisplayTextRole) {
    LBXDisplayTextRoleFixed,
    LBXDisplayTextRoleStatus,
    LBXDisplayTextRoleDiagnostic,
    LBXDisplayTextRoleUserData,
};
NSString *LBXDisplayCopy(NSString *text);
NSString *LBXDisplayText(NSString *text, LBXDisplayTextRole role);
// For source-created actions only. Existing alert actions remain unchanged.
NSString *LBXDisplayActionTitle(NSString *title);
// Only labels explicitly marked by an authored renderer participate in Apply.
void LBXDisplayCopySetRole(UILabel *label, LBXDisplayTextRole role);
void LBXDisplayCopyApply(UIViewController *controller);
// Recovered UI accent + observed manager-origin orange colors; no state/action changes.
BOOL LBXDisplayCopyInstallNativeAccent(void);
// Public view tint only; keeps every original alert action and handler intact.
void LBXDisplayCopyAlertTint(UIViewController *presented);
void LBXDisplayCopyAlert(UIViewController *presented);
void LBXDisplayCopyDiagnosticAlert(UIViewController *presented);

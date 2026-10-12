#import <UIKit/UIKit.h>

// Source-owned screens. The host remains responsible for admission and actions.
BOOL LBXWorkspaceApply(UIViewController *owner);
void LBXWorkspaceRefresh(UIViewController *owner);
NSDictionary *LBXWorkspaceStatus(void);
void LBXWorkspaceStyleTable(UITableView *table);
void LBXWorkspaceStyleCell(UITableViewCell *cell);

// Only presentation strings: never apply this to user input, identifiers or URLs.
NSString *LBXWorkspaceHeading(NSString *heading);

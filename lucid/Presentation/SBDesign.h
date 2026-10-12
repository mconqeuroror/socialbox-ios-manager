#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT UIColor *SBInk(void);
FOUNDATION_EXPORT UIColor *SBPanel(void);
FOUNDATION_EXPORT UIColor *SBAccent(void);
FOUNDATION_EXPORT UIColor *SBMuted(void);
// Locally drawn paths; no inherited artwork or SF-symbol navigation glyphs.
FOUNDATION_EXPORT UIImage *SBGlyph(NSString *name);
FOUNDATION_EXPORT UILabel *SBLabel(NSString *text, CGFloat size, UIFontWeight weight);
FOUNDATION_EXPORT UIButton *SBButton(NSString *title, NSString *glyph, BOOL primary, void (^ _Nullable action)(void));
FOUNDATION_EXPORT void SBShowUnavailable(UIViewController *owner, NSString *reason);
NS_ASSUME_NONNULL_END

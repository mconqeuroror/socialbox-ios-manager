#import <Preferences/Preferences.h>

// Feature 4 — operator dashboard. Non-technical design: big labels, minimal
// text, one row per container, tap for the common actions.
//
// Header (always visible):
//   Keys X / ~100 (device)          red >=95, yellow >=80
//   Leaks: N                        count of alerts
//   Attest default: ON/OFF
//
// Per container: nickname -> "● status · karma N · group A · attest ON"
// Tap -> action sheet: Refresh health / Rotate container / Pause.
//
// A/B Report section (Feature 5) computed from the store.

@interface RBXDashboardController : PSListController

@end

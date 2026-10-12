#pragma once
#import <Foundation/Foundation.h>
#import <math.h>

// UI-001/UI-004: presentation only. These labels never authorize a launch.
static inline NSString *RBXOperatorText(NSString *key) {
    NSDictionary *words = @{
        @"PASS": @"PASS", @"FAIL": @"FAIL", @"NOT_RUN": @"NOT VERIFIED",
        @"pass": @"PASS", @"fail": @"FAIL", @"info": @"NOT VERIFIED",
        @"advanced": @"Open advanced", @"idle": @"Idle", @"opening": @"Opening",
        @"ready": @"Ready", @"locked": @"Locked", @"checks": @"Run checks",
        @"waiting": @"Waiting for the device to finish this step.",
        @"unavailable": @"Status is not verified. Run checks or open advanced setup.",
        @"proxy-assignment": @"Your cloud assigns this container's proxy. Opening verifies its assignment and live country.",
        @"generated": @"Identity is generated automatically. Creating a container does not open Reddit.",
        @"fallback": @"This step did not finish. Open advanced to inspect the full report.",
    };
    return words[key] ?: words[@"fallback"];
}

static inline NSString *RBXOperatorMessage(id message) {
    if (![message isKindOfClass:NSString.class] || ![message length]) return RBXOperatorText(@"fallback");
    NSString *text = message;
    NSArray *rules = @[
        @[@"bounded helper", @"A required device tool could not start. Open advanced diagnostics for details."],
        @[@"proxy country", @"The identity country must match the assigned proxy country. Review proxy setup before continuing."],
        @[@"locale does not belong", @"Choose a language and region that match the proxy country."],
        @[@"timezone does not belong", @"Choose a timezone that matches the proxy country."],
        @[@"carrier is not valid", @"Choose a carrier supported in the proxy country."],
        @[@"not supported by the synthetic model", @"Choose an iOS version supported by the selected model."],
        @[@"unknown device type", @"Choose a model from the supported device catalog."],
        @[@"identity is frozen", @"This identity has already been used. Create a new container to use a different identity."],
        @[@"recovery required", @"An earlier operation needs attention. Keep its data and open advanced diagnostics."],
        @[@"managed vpn is not", @"Complete managed VPN setup for this container before opening Reddit."],
        @[@"firewall is not", @"VPN protection is not ready. Open advanced setup and run checks again."],
        @[@"firewall not ready", @"VPN protection is not ready. Open advanced setup and run checks again."],
        @[@"hook readiness", @"The app's isolation checks are not ready. Traffic stays closed."],
        @[@"no current signed offline", @"Connect to the configured license server and verify activation."],
        @[@"license expired", @"Check license activation in Settings before continuing."],
        @[@"license activation required", @"Check license activation in Settings before continuing."],
        @[@"still encrypted", @"Import your decrypted Reddit IPA; the App Store copy cannot be used directly."],
        @[@"source is encrypted", @"Import your decrypted Reddit IPA; the App Store copy cannot be used directly."],
        @[@"insufficient free space", @"Free some device storage, then retry this step."],
        @[@"timed out", @"The device did not finish in time. Run checks before retrying."],
    ];
    NSString *lower = text.lowercaseString;
    for (NSArray *rule in rules) if ([lower containsString:rule[0]]) return rule[1];
    for (NSString *code in @[@"error domain=", @"code=", @"errno", @"osstatus", @"0x", @"com.redditbox."])
        if ([lower containsString:code]) return RBXOperatorText(@"fallback");
    return text;
}

static inline NSString *RBXOperatorCountry(id value) {
    NSString *country = [value isKindOfClass:NSString.class] ? [value uppercaseString] : @"";
    if (country.length != 2) return @"Country not verified";
    unichar a = [country characterAtIndex:0], b = [country characterAtIndex:1];
    if (a < 'A' || a > 'Z' || b < 'A' || b > 'Z') return @"Country not verified";
    UTF32Char symbols[] = {0x1F1E6 + a - 'A', 0x1F1E6 + b - 'A'};
    NSString *flag = [[NSString alloc] initWithBytes:symbols length:sizeof(symbols) encoding:NSUTF32LittleEndianStringEncoding];
    return [NSString stringWithFormat:@"%@ %@", flag ?: @"", country];
}

// Presentation gate only; a ready snapshot never replaces daemon admission.
static inline NSString *RBXContainerSetupMessage(NSDictionary *state) {
    id setup = state[@"firewallSetup"];
    id ready = [setup isKindOfClass:NSDictionary.class] ? setup[@"ready"] : nil;
    if ([ready isKindOfClass:NSNumber.class] && [ready boolValue]) return nil;
    return @"This container cannot open yet because managed VPN protection is not configured. A proxy alone is not enough in this version. In Settings → Managed VPN, complete device supervision, MDM installation and the clone’s VPN assignment, then run Open Firewall Setup. Your container and imported IPA are kept.";
}

static inline NSDictionary *RBXSimpleContainerPresentation(NSDictionary *row, NSDictionary *state, NSTimeInterval now) {
    NSString *status = @"idle", *reason = @"Tap to open or switch to this container.";
    NSNumber *updated = [state[@"updatedAt"] isKindOfClass:NSNumber.class] ? state[@"updatedAt"] : nil;
    BOOL fresh = updated && isfinite(now) && now >= updated.doubleValue && now - updated.doubleValue <= 10;
    NSDictionary *replacement = [row[@"replacementState"] isKindOfClass:NSDictionary.class] ? row[@"replacementState"] : @{};
    NSDictionary *recovery = [state[@"operationRecovery"] isKindOfClass:NSDictionary.class] ? state[@"operationRecovery"] : @{};
    NSDictionary *setup = [state[@"firewallSetup"] isKindOfClass:NSDictionary.class] ? state[@"firewallSetup"] : @{};
    if (!fresh) { status = @"locked"; reason = RBXOperatorText(@"unavailable"); }
    else if ([row[@"launchBlockReason"] isKindOfClass:NSString.class] && [row[@"launchBlockReason"] length]) {
        status = @"locked"; reason = row[@"launchBlockReason"];
    } else if ([row[@"isolationSentinel"] isKindOfClass:NSDictionary.class] && [row[@"isolationSentinel"][@"alert"] isEqual:@YES]) {
        status = @"locked"; reason = @"Isolation alert. Opening is blocked; review Diagnostics.";
    }
    else if (row[@"profileError"]) {
        status = @"locked"; reason = @"This profile could not be read. Open advanced to review recovery options.";
    } else if (row[@"deletionState"]) {
        status = @"locked"; reason = @"Cleanup has not finished. Open advanced to retry cleanup.";
    } else if (replacement.count && ![replacement[@"phase"] isEqual:@"committed"]) {
        status = @"locked"; reason = @"Replacement has not finished. Open advanced to resume it.";
    } else if (recovery.count) {
        status = @"locked"; reason = @"An earlier operation needs attention. Open advanced to review its recovery report.";
    } else if ([row[@"isActive"] boolValue] && [state[@"networkState"] isEqual:@"open"] &&
               [row[@"vpnArmed"] boolValue] && [row[@"hooksReady"] boolValue]) {
        status = @"ready"; reason = @"This container is open. Run checks to review verification details.";
    } else if ([row[@"isActive"] boolValue] || [row[@"launchState"] isEqual:@"switching"]) {
        status = @"opening"; reason = @"The device is checking this container before allowing traffic.";
    } else if (![setup[@"ready"] boolValue]) {
        status = @"locked"; reason = @"Finish managed VPN setup before opening Reddit.";
    } else if (![row[@"proxyStatus"] isEqual:@"configured"]) reason = RBXOperatorText(@"proxy-assignment");
    return @{@"status":status, @"title":RBXOperatorText(status), @"reason":reason};
}

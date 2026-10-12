#pragma once
#import <Foundation/Foundation.h>
#import <math.h>

// UI-002: a failed UI step may be reset only after its exact terminal receipt
// and a newer, fresh daemon snapshot prove no container exists. Interrupted or
// unobserved work stays pending; reset never resubmits a request automatically.
static inline BOOL RBXWizardDraftCanReset(NSDictionary *draft, NSDictionary *terminal,
    NSDictionary *state, BOOL pending, NSTimeInterval now) {
    if (pending || !isfinite(now) || ![draft isKindOfClass:NSDictionary.class] ||
        ![terminal isKindOfClass:NSDictionary.class] || ![state isKindOfClass:NSDictionary.class]) return NO;
    NSString *container = draft[@"container"], *request = draft[@"requestId"];
    if (![container isKindOfClass:NSString.class] || !container.length ||
        ![request isKindOfClass:NSString.class] || !request.length ||
        ![terminal[@"requestId"] isEqual:request] || ![terminal[@"containerId"] isEqual:container] ||
        ![terminal[@"action"] isEqual:@"createContainer"] || ![terminal[@"state"] isEqual:@"failed"] ||
        ![terminal[@"ok"] isEqual:@NO] || ![terminal[@"updatedAt"] isKindOfClass:NSNumber.class] ||
        ![state[@"updatedAt"] isKindOfClass:NSNumber.class] || ![state[@"containers"] isKindOfClass:NSArray.class]) return NO;
    double updated = [state[@"updatedAt"] doubleValue], completed = [terminal[@"updatedAt"] doubleValue];
    if (!isfinite(updated) || !isfinite(completed) || updated < completed || now < updated || now - updated > 10) return NO;
    id recovery = state[@"operationRecovery"];
    if (recovery && (![recovery isKindOfClass:NSDictionary.class] || [recovery count])) return NO;
    for (NSString *key in @[@"profileWarning", @"deletionWarning"]) {
        id warning = state[key];
        if (warning && (![warning isKindOfClass:NSString.class] || [warning length])) return NO;
    }
    for (id row in state[@"containers"]) {
        if (![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] ||
            [row[@"id"] isEqual:container]) return NO;
    }
    return YES;
}

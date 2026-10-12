#pragma once
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface SBLocationSimulator : NSObject
+ (BOOL)available;
- (BOOL)startAt:(CLLocationCoordinate2D)coordinate error:(NSError **)error;
- (BOOL)stop:(NSError **)error;
@end

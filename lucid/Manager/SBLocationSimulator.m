#import "SBLocationSimulator.h"

@implementation SBLocationSimulator {
    id _manager;
}

static Class SBSimClass(void) {
    Class cls = NSClassFromString(@"CLSimulationManager");
    return cls ?: NSClassFromString(@"CLsimulationManager");
}

+ (BOOL)available {
    return SBSimClass() != Nil;
}

- (id)manager:(NSError **)error {
    if (_manager) return _manager;
    Class cls = SBSimClass();
    if (!cls) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.location" code:10
                                     userInfo:@{NSLocalizedDescriptionKey : @"Location simulation is unavailable on this device."}];
        return nil;
    }
    _manager = [cls new];
    if ([_manager respondsToSelector:NSSelectorFromString(@"setLocationInterval:")]) {
        [_manager setValue:@1.0 forKey:@"locationInterval"];
    }
    return _manager;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
- (void)send:(id)manager name:(NSString *)name object:(id)object {
    SEL sel = NSSelectorFromString(name);
    if (![manager respondsToSelector:sel]) return;
    if (object) [manager performSelector:sel withObject:object];
    else [manager performSelector:sel];
}
#pragma clang diagnostic pop

- (BOOL)startAt:(CLLocationCoordinate2D)coordinate error:(NSError **)error {
    if (!CLLocationCoordinate2DIsValid(coordinate) || fabs(coordinate.latitude) > 90 ||
        fabs(coordinate.longitude) > 180) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.location" code:11
                                     userInfo:@{NSLocalizedDescriptionKey : @"Choose a place on the map first."}];
        return NO;
    }
    id manager = [self manager:error];
    if (!manager) return NO;
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:coordinate
                                                         altitude:12
                                               horizontalAccuracy:5
                                                 verticalAccuracy:5
                                                        timestamp:NSDate.date];
    [self send:manager name:@"stopLocationSimulation" object:nil];
    [self send:manager name:@"clearSimulatedLocations" object:nil];
    [self send:manager name:@"appendSimulatedLocation:" object:location];
    [self send:manager name:@"flush" object:nil];
    [self send:manager name:@"startLocationSimulation" object:nil];
    return YES;
}

- (BOOL)stop:(NSError **)error {
    id manager = [self manager:error];
    if (!manager) return NO;
    [self send:manager name:@"stopLocationSimulation" object:nil];
    [self send:manager name:@"clearSimulatedLocations" object:nil];
    [self send:manager name:@"flush" object:nil];
    return YES;
}

@end

#pragma once
#import <Foundation/Foundation.h>

BOOL LBXHelperStartLocationSimulation(double latitude, double longitude, NSString **detail, NSError **error);
BOOL LBXHelperStopLocationSimulation(NSString **detail, NSError **error);

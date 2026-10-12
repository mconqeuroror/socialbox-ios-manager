#pragma once
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@class SBSlippyMapView;

@protocol SBSlippyMapViewDelegate <NSObject>
- (void)slippyMap:(SBSlippyMapView *)map didPickCoordinate:(CLLocationCoordinate2D)coordinate;
@end

@interface SBSlippyMapView : UIView
@property(nonatomic, weak) id<SBSlippyMapViewDelegate> delegate;
@property(nonatomic) CLLocationCoordinate2D centerCoordinate;
@property(nonatomic) NSInteger zoom;
@property(nonatomic) CLLocationCoordinate2D pinCoordinate;
@property(nonatomic) BOOL satellite;
- (void)setCenterCoordinate:(CLLocationCoordinate2D)coordinate zoom:(NSInteger)zoom;
@end

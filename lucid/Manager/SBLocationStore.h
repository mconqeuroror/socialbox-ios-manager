#pragma once
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface SBLocationPlace : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CLLocationCoordinate2D coordinate;
- (NSString *)coordinateText;
@end

@interface SBLocationStore : NSObject
@property(nonatomic) CLLocationCoordinate2D coordinate;
@property(nonatomic, copy) NSString *address;
@property(nonatomic) BOOL enabled;
@property(nonatomic) NSInteger mapType;
@property(nonatomic, copy) NSArray<SBLocationPlace *> *bookmarks;
@property(nonatomic, copy) NSArray<SBLocationPlace *> *history;
- (BOOL)hasCoordinate;
- (BOOL)load:(NSError **)error;
- (BOOL)save:(NSError **)error;
- (void)addBookmarkNamed:(NSString *)name;
- (void)addHistoryNamed:(NSString *)name;
- (void)removeBookmarkAtIndex:(NSUInteger)index;
+ (BOOL)parseText:(NSString *)text intoCoordinate:(CLLocationCoordinate2D *)coordinate;
@end

#import "SBLocationStore.h"

static NSString *const SBLocationStorePath = @"/private/var/mobile/Library/SocialBox/Location.plist";

@implementation SBLocationPlace
- (NSString *)coordinateText {
    return [NSString stringWithFormat:@"%.6f, %.6f", self.coordinate.latitude, self.coordinate.longitude];
}
- (NSDictionary *)dictionary {
    return @{
        @"name" : self.name ?: @"",
        @"lat" : @(self.coordinate.latitude),
        @"lon" : @(self.coordinate.longitude),
    };
}
+ (instancetype)fromDictionary:(NSDictionary *)row {
    if (![row isKindOfClass:NSDictionary.class]) return nil;
    double lat = [row[@"lat"] doubleValue];
    double lon = [row[@"lon"] doubleValue];
    if (!CLLocationCoordinate2DIsValid((CLLocationCoordinate2D){lat, lon})) return nil;
    if (fabs(lat) > 90 || fabs(lon) > 180) return nil;
    SBLocationPlace *place = [SBLocationPlace new];
    place.name = [row[@"name"] isKindOfClass:NSString.class] ? row[@"name"] : @"";
    place.coordinate = CLLocationCoordinate2DMake(lat, lon);
    return place;
}
@end

@implementation SBLocationStore

- (instancetype)init {
    if ((self = [super init])) {
        _coordinate = kCLLocationCoordinate2DInvalid;
        _address = @"";
        _bookmarks = @[];
        _history = @[];
    }
    return self;
}

- (BOOL)hasCoordinate {
    return CLLocationCoordinate2DIsValid(self.coordinate) && fabs(self.coordinate.latitude) <= 90 &&
           fabs(self.coordinate.longitude) <= 180;
}

+ (BOOL)parseText:(NSString *)text intoCoordinate:(CLLocationCoordinate2D *)coordinate {
    if (![text isKindOfClass:NSString.class] || !coordinate) return NO;
    NSString *trimmed =
        [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *rx = [NSRegularExpression
        regularExpressionWithPattern:@"^(-?[0-9]+(?:\\.[0-9]+)?)[\\s,;]+(-?[0-9]+(?:\\.[0-9]+)?)$"
                             options:0
                               error:nil];
    NSTextCheckingResult *m = [rx firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (!m) return NO;
    double lat = [[trimmed substringWithRange:[m rangeAtIndex:1]] doubleValue];
    double lon = [[trimmed substringWithRange:[m rangeAtIndex:2]] doubleValue];
    if (fabs(lat) > 90 || fabs(lon) > 180) return NO;
    *coordinate = CLLocationCoordinate2DMake(lat, lon);
    return YES;
}

- (NSArray<SBLocationPlace *> *)placesFromRows:(id)rows {
    if (![rows isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id row in rows) {
        SBLocationPlace *place = [SBLocationPlace fromDictionary:row];
        if (place) [out addObject:place];
    }
    return out;
}

- (NSArray *)rowsFromPlaces:(NSArray<SBLocationPlace *> *)places {
    NSMutableArray *out = [NSMutableArray array];
    for (SBLocationPlace *place in places) [out addObject:place.dictionary];
    return out;
}

- (BOOL)load:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:SBLocationStorePath]) return YES;
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:SBLocationStorePath];
    if (![root isKindOfClass:NSDictionary.class]) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.location" code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"Saved location is unreadable."}];
        return NO;
    }
    double lat = [root[@"lat"] doubleValue];
    double lon = [root[@"lon"] doubleValue];
    if (fabs(lat) <= 90 && fabs(lon) <= 180 && (lat != 0 || lon != 0 || root[@"lat"])) {
        self.coordinate = CLLocationCoordinate2DMake(lat, lon);
    }
    self.address = [root[@"address"] isKindOfClass:NSString.class] ? root[@"address"] : @"";
    self.enabled = [root[@"enabled"] boolValue];
    self.mapType = [root[@"mapType"] integerValue];
    self.bookmarks = [self placesFromRows:root[@"bookmarks"]];
    self.history = [self placesFromRows:root[@"history"]];
    return YES;
}

- (BOOL)save:(NSError **)error {
    [[NSFileManager defaultManager] createDirectoryAtPath:SBLocationStorePath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSDictionary *root = @{
        @"lat" : @(self.hasCoordinate ? self.coordinate.latitude : 0),
        @"lon" : @(self.hasCoordinate ? self.coordinate.longitude : 0),
        @"address" : self.address ?: @"",
        @"enabled" : @(self.enabled),
        @"mapType" : @(self.mapType),
        @"bookmarks" : [self rowsFromPlaces:self.bookmarks],
        @"history" : [self rowsFromPlaces:self.history],
    };
    if (![root writeToFile:SBLocationStorePath atomically:YES]) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.location" code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"Could not save the location."}];
        return NO;
    }
    return YES;
}

- (void)insertPlaceNamed:(NSString *)name intoKey:(NSString *)key limit:(NSUInteger)limit {
    if (!self.hasCoordinate) return;
    SBLocationPlace *place = [SBLocationPlace new];
    place.name = name.length ? name : self.address;
    if (!place.name.length) place.name = [NSString stringWithFormat:@"%.5f, %.5f", self.coordinate.latitude, self.coordinate.longitude];
    place.coordinate = self.coordinate;
    NSMutableArray *rows = [[key isEqual:@"bookmarks"] ? self.bookmarks : self.history mutableCopy] ?: [NSMutableArray array];
    [rows filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SBLocationPlace *row, NSDictionary *b) {
        (void)b;
        return !(fabs(row.coordinate.latitude - place.coordinate.latitude) < 0.00001 &&
                 fabs(row.coordinate.longitude - place.coordinate.longitude) < 0.00001);
    }]];
    [rows insertObject:place atIndex:0];
    while (rows.count > limit) [rows removeLastObject];
    if ([key isEqual:@"bookmarks"]) self.bookmarks = rows;
    else self.history = rows;
}

- (void)addBookmarkNamed:(NSString *)name {
    [self insertPlaceNamed:name intoKey:@"bookmarks" limit:40];
}

- (void)addHistoryNamed:(NSString *)name {
    [self insertPlaceNamed:name intoKey:@"history" limit:30];
}

- (void)removeBookmarkAtIndex:(NSUInteger)index {
    if (index >= self.bookmarks.count) return;
    NSMutableArray *rows = [self.bookmarks mutableCopy];
    [rows removeObjectAtIndex:index];
    self.bookmarks = rows;
}

@end

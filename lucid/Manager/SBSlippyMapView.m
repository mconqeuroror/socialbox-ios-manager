#import "SBSlippyMapView.h"
#include <math.h>

static const CGFloat SBTileSize = 256;

static double SBWrap(double value, double max) {
    double m = fmod(value, max);
    return m < 0 ? m + max : m;
}

static void SBProject(CLLocationCoordinate2D c, NSInteger zoom, double *x, double *y) {
    double n = pow(2, zoom);
    double lat = MIN(MAX(c.latitude, -85.0511), 85.0511);
    double rad = lat * M_PI / 180.0;
    *x = (c.longitude + 180.0) / 360.0 * n;
    *y = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / M_PI) / 2.0 * n;
}

static CLLocationCoordinate2D SBUnproject(double x, double y, NSInteger zoom) {
    double n = pow(2, zoom);
    double lon = x / n * 360.0 - 180.0;
    double rad = M_PI * (1.0 - 2.0 * y / n);
    double lat = 180.0 / M_PI * atan(sinh(rad));
    return CLLocationCoordinate2DMake(MIN(MAX(lat, -85.0511), 85.0511), lon);
}

@interface SBSlippyMapView ()
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIImageView *> *tiles;
@property(nonatomic, strong) NSMutableSet<NSString *> *loading;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *cache;
@property(nonatomic, strong) UIView *pinView;
@property(nonatomic, strong) UILabel *hint;
@property(nonatomic) CGSize laidOutSize;
@end

@implementation SBSlippyMapView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _centerCoordinate = CLLocationCoordinate2DMake(48.1486, 17.1077);
        _zoom = 5;
        _pinCoordinate = kCLLocationCoordinate2DInvalid;
        _tiles = [NSMutableDictionary dictionary];
        _loading = [NSMutableSet set];
        _cache = [NSCache new];
        _cache.countLimit = 128;
        self.backgroundColor = [UIColor colorWithRed:0.07 green:0.10 blue:0.12 alpha:1];
        self.clipsToBounds = YES;
        self.accessibilityIdentifier = @"socialbox.location.map";

        _hint = [[UILabel alloc] initWithFrame:CGRectZero];
        _hint.text = @"Tap to drop a pin · drag to move · pinch to zoom";
        _hint.textColor = [UIColor colorWithWhite:0.85 alpha:0.9];
        _hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _hint.textAlignment = NSTextAlignmentCenter;
        _hint.numberOfLines = 2;
        [self addSubview:_hint];

        _pinView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
        _pinView.backgroundColor = [UIColor colorWithRed:0 green:122.0 / 255.0 blue:1 alpha:1];
        _pinView.layer.borderColor = UIColor.whiteColor.CGColor;
        _pinView.layer.borderWidth = 2;
        _pinView.layer.cornerRadius = 9;
        _pinView.hidden = YES;
        [self addSubview:_pinView];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
        [self addGestureRecognizer:pan];
        [self addGestureRecognizer:pinch];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.hint.frame = CGRectMake(10, self.bounds.size.height - 36, self.bounds.size.width - 20, 28);
    if (CGSizeEqualToSize(self.bounds.size, self.laidOutSize)) {
        [self positionPin];
        return;
    }
    self.laidOutSize = self.bounds.size;
    [self reloadTiles];
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.12].CGColor);
    CGContextSetLineWidth(ctx, 1);
    NSInteger lines = 8;
    for (NSInteger i = 1; i < lines; i++) {
        CGFloat x = self.bounds.size.width * i / lines;
        CGFloat y = self.bounds.size.height * i / lines;
        CGContextMoveToPoint(ctx, x, 0);
        CGContextAddLineToPoint(ctx, x, self.bounds.size.height);
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, self.bounds.size.width, y);
    }
    CGContextStrokePath(ctx);
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)coordinate zoom:(NSInteger)zoom {
    _centerCoordinate = coordinate;
    _zoom = MIN(MAX(zoom, 2), 18);
    [self reloadTiles];
}

- (void)setCenterCoordinate:(CLLocationCoordinate2D)centerCoordinate {
    _centerCoordinate = centerCoordinate;
    [self reloadTiles];
}

- (void)setZoom:(NSInteger)zoom {
    _zoom = MIN(MAX(zoom, 2), 18);
    [self reloadTiles];
}

- (void)setPinCoordinate:(CLLocationCoordinate2D)pinCoordinate {
    _pinCoordinate = pinCoordinate;
    [self positionPin];
}

- (void)setSatellite:(BOOL)satellite {
    _satellite = satellite;
    [self.tiles.allValues makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [self.tiles removeAllObjects];
    [self reloadTiles];
}

- (NSString *)urlForX:(NSInteger)x y:(NSInteger)y z:(NSInteger)z {
    NSInteger n = 1 << z;
    x = (NSInteger)SBWrap(x, n);
    if (y < 0 || y >= n) return nil;
    if (self.satellite) {
        return [NSString stringWithFormat:@"https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%ld/%ld/%ld",
                                          (long)z, (long)y, (long)x];
    }
    return [NSString stringWithFormat:@"https://tile.openstreetmap.org/%ld/%ld/%ld.png", (long)z, (long)x, (long)y];
}

- (void)reloadTiles {
    if (self.bounds.size.width < 2 || self.bounds.size.height < 2) return;
    double cx, cy;
    SBProject(self.centerCoordinate, self.zoom, &cx, &cy);
    CGFloat originX = (CGFloat)(cx * SBTileSize - self.bounds.size.width / 2);
    CGFloat originY = (CGFloat)(cy * SBTileSize - self.bounds.size.height / 2);
    NSInteger x0 = (NSInteger)floor(originX / SBTileSize);
    NSInteger y0 = (NSInteger)floor(originY / SBTileSize);
    NSInteger cols = (NSInteger)ceil(self.bounds.size.width / SBTileSize) + 2;
    NSInteger rows = (NSInteger)ceil(self.bounds.size.height / SBTileSize) + 2;
    NSMutableSet *keep = [NSMutableSet set];
    for (NSInteger iy = 0; iy < rows; iy++) {
        for (NSInteger ix = 0; ix < cols; ix++) {
            NSInteger tx = x0 + ix, ty = y0 + iy;
            NSString *url = [self urlForX:tx y:ty z:self.zoom];
            if (!url) continue;
            [keep addObject:url];
            UIImageView *view = self.tiles[url];
            if (!view) {
                view = [[UIImageView alloc] initWithFrame:CGRectZero];
                view.contentMode = UIViewContentModeScaleToFill;
                view.backgroundColor = UIColor.clearColor;
                [self insertSubview:view belowSubview:self.pinView];
                self.tiles[url] = view;
                UIImage *cached = [self.cache objectForKey:url];
                if (cached) view.image = cached;
                else [self fetch:url into:view];
            }
            view.frame = CGRectMake(tx * SBTileSize - originX, ty * SBTileSize - originY, SBTileSize, SBTileSize);
        }
    }
    NSArray *keys = self.tiles.allKeys;
    for (NSString *key in keys) {
        if ([keep containsObject:key]) continue;
        [self.tiles[key] removeFromSuperview];
        [self.tiles removeObjectForKey:key];
    }
    [self positionPin];
    [self bringSubviewToFront:self.hint];
    [self bringSubviewToFront:self.pinView];
}

- (void)fetch:(NSString *)url into:(UIImageView *)view {
    if ([self.loading containsObject:url]) return;
    [self.loading addObject:url];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 15;
    [request setValue:@"SocialBox/3.1 location-map" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         (void)response;
                                         (void)error;
                                         UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
                                         dispatch_async(dispatch_get_main_queue(), ^{
                                             [weakSelf.loading removeObject:url];
                                             if (!image) return;
                                             [weakSelf.cache setObject:image forKey:url];
                                             UIImageView *tile = weakSelf.tiles[url];
                                             if (tile) {
                                                 tile.image = image;
                                                 weakSelf.hint.hidden = YES;
                                             }
                                         });
                                     }] resume];
}

- (void)positionPin {
    if (!CLLocationCoordinate2DIsValid(self.pinCoordinate)) {
        self.pinView.hidden = YES;
        return;
    }
    double cx, cy, px, py;
    SBProject(self.centerCoordinate, self.zoom, &cx, &cy);
    SBProject(self.pinCoordinate, self.zoom, &px, &py);
    CGFloat x = (CGFloat)((px - cx) * SBTileSize + self.bounds.size.width / 2);
    CGFloat y = (CGFloat)((py - cy) * SBTileSize + self.bounds.size.height / 2);
    self.pinView.center = CGPointMake(x, y - 4);
    self.pinView.hidden = NO;
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self];
    [pan setTranslation:CGPointZero inView:self];
    double cx, cy;
    SBProject(self.centerCoordinate, self.zoom, &cx, &cy);
    cx -= delta.x / SBTileSize;
    cy -= delta.y / SBTileSize;
    self.centerCoordinate = SBUnproject(cx, cy, self.zoom);
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state != UIGestureRecognizerStateChanged && pinch.state != UIGestureRecognizerStateEnded) return;
    if (pinch.scale > 1.25) {
        self.zoom = self.zoom + 1;
        pinch.scale = 1;
    } else if (pinch.scale < 0.8) {
        self.zoom = self.zoom - 1;
        pinch.scale = 1;
    }
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    CGPoint p = [tap locationInView:self];
    double cx, cy;
    SBProject(self.centerCoordinate, self.zoom, &cx, &cy);
    cx += (p.x - self.bounds.size.width / 2) / SBTileSize;
    cy += (p.y - self.bounds.size.height / 2) / SBTileSize;
    CLLocationCoordinate2D c = SBUnproject(cx, cy, self.zoom);
    self.pinCoordinate = c;
    self.hint.hidden = YES;
    [self.delegate slippyMap:self didPickCoordinate:c];
}

@end

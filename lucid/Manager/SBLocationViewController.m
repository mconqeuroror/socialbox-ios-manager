#import "SBLocationViewController.h"
#import "SBLocationStore.h"
#import "SBLocationSimulator.h"
#import "SBSlippyMapView.h"
#import "SBDesign.h"
#import "SBInterfaceCopy.h"
#import "../HelperClient/LBXHelperClient.h"
#import <CoreLocation/CoreLocation.h>

@interface SBLocationViewController () <UISearchBarDelegate, SBSlippyMapViewDelegate, CLLocationManagerDelegate>
@property(nonatomic, strong) SBSlippyMapView *mapView;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UILabel *coordinatesLabel;
@property(nonatomic, strong) UILabel *addressLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *actionButton;
@property(nonatomic, strong) SBLocationStore *store;
@property(nonatomic, strong) SBLocationSimulator *simulator;
@property(nonatomic, strong) CLLocationManager *deviceLocation;
@property(nonatomic, copy) NSString *pendingDeviceAction;
@end

@implementation SBLocationViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SBUIText(@"nav.location");
    self.view.backgroundColor = SBInk();
    self.view.tintColor = SBAccent();
    self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.accessibilityIdentifier = @"socialbox.location";
    self.store = [SBLocationStore new];
    self.simulator = [SBLocationSimulator new];
    [self.store load:nil];

    self.searchBar = [UISearchBar new];
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = SBUIText(@"location.searchPlaceholder");
    self.searchBar.barStyle = UIBarStyleBlack;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeWords;
    self.searchBar.accessibilityIdentifier = @"socialbox.location.search";
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.mapView = [[SBSlippyMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.layer.cornerRadius = 12;
    self.mapView.clipsToBounds = YES;
    self.mapView.satellite = self.store.mapType == 1;
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.mapView setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [self.mapView setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisVertical];

    self.coordinatesLabel = SBLabel(@"—", 20, UIFontWeightSemibold);
    self.coordinatesLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightSemibold];
    self.coordinatesLabel.accessibilityIdentifier = @"socialbox.location.coordinates";
    self.addressLabel = SBLabel(SBUIText(@"location.pickHint"), 13, UIFontWeightRegular);
    self.addressLabel.textColor = SBMuted();
    self.addressLabel.accessibilityIdentifier = @"socialbox.location.address";
    self.statusLabel = SBLabel(@"", 13, UIFontWeightRegular);
    self.statusLabel.textColor = SBMuted();
    self.statusLabel.accessibilityIdentifier = @"socialbox.location.status";

    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    [more setTitle:SBUIText(@"location.tools") forState:UIControlStateNormal];
    more.showsMenuAsPrimaryAction = YES;
    more.tintColor = UIColor.whiteColor;
    more.accessibilityIdentifier = @"socialbox.location.tools";
    more.menu = [self toolsMenu];
    more.translatesAutoresizingMaskIntoConstraints = NO;

    __weak typeof(self) weakSelf = self;
    self.actionButton = SBButton(SBUIText(@"location.start"), @"location", YES, ^{ [weakSelf toggleSimulation]; });
    self.actionButton.accessibilityIdentifier = @"socialbox.location.button";
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *panel = [UIView new];
    panel.backgroundColor = SBPanel();
    panel.layer.cornerRadius = 14;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *copy = [[UIStackView alloc]
        initWithArrangedSubviews:@[ self.coordinatesLabel, self.addressLabel, self.statusLabel, more ]];
    copy.axis = UILayoutConstraintAxisVertical;
    copy.spacing = 6;
    copy.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:copy];
    [panel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [self.view addSubview:self.searchBar];
    [self.view addSubview:self.mapView];
    [self.view addSubview:panel];
    [self.view addSubview:self.actionButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.mapView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.mapView.bottomAnchor constraintEqualToAnchor:panel.topAnchor constant:-10],
        [self.mapView.heightAnchor constraintGreaterThanOrEqualToConstant:260],
        [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [panel.bottomAnchor constraintEqualToAnchor:self.actionButton.topAnchor constant:-10],
        [copy.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [copy.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [copy.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],
        [copy.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-14],
        [self.actionButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.actionButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.actionButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.actionButton.heightAnchor constraintGreaterThanOrEqualToConstant:48],
    ]];

    if (self.store.hasCoordinate) {
        self.coordinatesLabel.text =
            [NSString stringWithFormat:@"%.6f, %.6f", self.store.coordinate.latitude, self.store.coordinate.longitude];
        self.addressLabel.text = self.store.address.length ? self.store.address : SBUIText(@"location.dropped");
        [self.mapView setCenterCoordinate:self.store.coordinate zoom:12];
        self.mapView.pinCoordinate = self.store.coordinate;
    }
    [self refreshAction];
    if (self.store.enabled && self.store.hasCoordinate) {
        [self applySimulation:YES];
    }
}

- (UIMenu *)toolsMenu {
    __weak typeof(self) weakSelf = self;
    return [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:SBUIText(@"location.bookmarks") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf showList:@"bookmarks"]; }],
        [UIAction actionWithTitle:SBUIText(@"location.savePlace") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf saveBookmark]; }],
        [UIAction actionWithTitle:SBUIText(@"location.history") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf showList:@"history"]; }],
        [UIAction actionWithTitle:SBUIText(@"location.mapStyle") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf cycleMapType]; }],
        [UIAction actionWithTitle:SBUIText(@"location.useDevice") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf locateDevice]; }],
        [UIAction actionWithTitle:SBUIText(@"location.copyCoordinates") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf copyCoordinates]; }],
        [UIAction actionWithTitle:SBUIText(@"location.verify") image:nil identifier:nil handler:^(__unused UIAction *a) { [weakSelf verifyReported]; }],
    ]];
}

- (void)refreshAction {
    BOOL on = self.store.enabled;
    UIButtonConfiguration *config = UIButtonConfiguration.filledButtonConfiguration;
    config.title = SBUIText(on ? @"location.stop" : @"location.start");
    config.image = SBGlyph(@"location");
    config.imagePadding = 12;
    config.baseForegroundColor = on ? UIColor.whiteColor : SBInk();
    config.baseBackgroundColor = on ? [UIColor colorWithRed:0.75 green:0.18 blue:0.16 alpha:1] : SBAccent();
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    config.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
    self.actionButton.configuration = config;
    self.statusLabel.text = on ? SBUIText(@"location.running")
                               : (self.store.hasCoordinate ? SBUIText(@"location.ready") : SBUIText(@"location.pickHint"));
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SBUIText(@"nav.location")
                                                                   message:error.localizedDescription ?: SBUIText(@"common.unavailable")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCoordinate:(CLLocationCoordinate2D)coordinate title:(NSString *)title {
    self.store.coordinate = coordinate;
    if (title.length) self.store.address = title;
    self.coordinatesLabel.text = [NSString stringWithFormat:@"%.6f, %.6f", coordinate.latitude, coordinate.longitude];
    self.addressLabel.text = title.length ? title : SBUIText(@"location.dropped");
    [self.store save:nil];
    [self refreshAction];
    [self.mapView setCenterCoordinate:coordinate zoom:MAX(self.mapView.zoom, 12)];
    self.mapView.pinCoordinate = coordinate;
    if (!title.length) [self reverseGeocode:coordinate];
    if (self.store.enabled) [self applySimulation:YES];
}

- (void)slippyMap:(SBSlippyMapView *)map didPickCoordinate:(CLLocationCoordinate2D)coordinate {
    (void)map;
    [self showCoordinate:coordinate title:nil];
}

- (void)reverseGeocode:(CLLocationCoordinate2D)coordinate {
    NSString *url = [NSString stringWithFormat:@"https://nominatim.openstreetmap.org/reverse?lat=%f&lon=%f&format=json",
                                               coordinate.latitude, coordinate.longitude];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:@"SocialBox/3.1 location-map" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         (void)response;
                                         (void)error;
                                         NSDictionary *row = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                                         NSString *name = [row isKindOfClass:NSDictionary.class] ? row[@"display_name"] : nil;
                                         if (!name.length) return;
                                         dispatch_async(dispatch_get_main_queue(), ^{
                                             weakSelf.store.address = name;
                                             weakSelf.addressLabel.text = name;
                                             [weakSelf.store save:nil];
                                         });
                                     }] resume];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return;
    CLLocationCoordinate2D parsed;
    if ([SBLocationStore parseText:query intoCoordinate:&parsed]) {
        [self showCoordinate:parsed title:query];
        return;
    }
    NSString *encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://nominatim.openstreetmap.org/search?q=%@&format=json&limit=1", encoded]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"SocialBox/3.1 location-map" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         (void)response;
                                         NSArray *rows = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                                         NSDictionary *row = [rows isKindOfClass:NSArray.class] ? rows.firstObject : nil;
                                         dispatch_async(dispatch_get_main_queue(), ^{
                                             if (![row isKindOfClass:NSDictionary.class]) {
                                                 [weakSelf showError:error ?: [NSError errorWithDomain:@"com.socialbox.location" code:12
                                                     userInfo:@{NSLocalizedDescriptionKey : @"No place matched that search."}]];
                                                 return;
                                             }
                                             [weakSelf showCoordinate:CLLocationCoordinate2DMake([row[@"lat"] doubleValue], [row[@"lon"] doubleValue])
                                                                title:row[@"display_name"]];
                                         });
                                     }] resume];
}

- (void)applySimulation:(BOOL)start {
    CLLocationCoordinate2D coordinate = self.store.coordinate;
    if (start && !self.store.hasCoordinate) {
        [self showError:[NSError errorWithDomain:@"com.socialbox.location" code:11
                                        userInfo:@{NSLocalizedDescriptionKey : SBUIText(@"location.pickHint")}]];
        return;
    }
    self.actionButton.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *detail = nil;
        LBXHelperClient *helper = [LBXHelperClient new];
        BOOL ok = start ? [helper startLocationAtLatitude:coordinate.latitude
                                               longitude:coordinate.longitude
                                                  detail:&detail
                                                   error:&error]
                        : [helper stopLocationSimulation:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.actionButton.enabled = YES;
            if (!ok) {
                [self showError:error];
                return;
            }
            self.store.enabled = start;
            if (start) [self.store addHistoryNamed:self.store.address];
            [self.store save:nil];
            [self refreshAction];
            if (detail.length) self.statusLabel.text = detail;
        });
    });
}

- (void)toggleSimulation {
    [self applySimulation:!self.store.enabled];
}

- (void)saveBookmark {
    if (!self.store.hasCoordinate) {
        [self showError:[NSError errorWithDomain:@"com.socialbox.location" code:13
                                        userInfo:@{NSLocalizedDescriptionKey : SBUIText(@"location.pickHint")}]];
        return;
    }
    [self.store addBookmarkNamed:self.store.address];
    [self.store save:nil];
    self.statusLabel.text = SBUIText(@"location.saved");
}

- (void)showList:(NSString *)kind {
    NSArray<SBLocationPlace *> *rows = [kind isEqual:@"bookmarks"] ? self.store.bookmarks : self.store.history;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:SBUIText([kind isEqual:@"bookmarks"] ? @"location.bookmarks" : @"location.history")
                         message:rows.count ? nil : SBUIText(@"location.emptyList")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (SBLocationPlace *place in rows) {
        NSString *title = [NSString stringWithFormat:@"%@  %@", place.name, place.coordinateText];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            [weakSelf showCoordinate:place.coordinate title:place.name];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)cycleMapType {
    self.store.mapType = self.store.mapType == 0 ? 1 : 0;
    [self.store save:nil];
    self.mapView.satellite = self.store.mapType == 1;
}

- (void)copyCoordinates {
    if (!self.store.hasCoordinate) return;
    UIPasteboard.generalPasteboard.string =
        [NSString stringWithFormat:@"%.6f, %.6f", self.store.coordinate.latitude, self.store.coordinate.longitude];
    self.statusLabel.text = SBUIText(@"location.copied");
}

- (void)ensureDeviceLocation:(NSString *)action {
    if (!self.deviceLocation) {
        self.deviceLocation = [CLLocationManager new];
        self.deviceLocation.delegate = self;
        self.deviceLocation.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    }
    self.pendingDeviceAction = action;
    if (self.deviceLocation.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self.deviceLocation requestWhenInUseAuthorization];
        return;
    }
    [self.deviceLocation requestLocation];
}

- (void)locateDevice {
    [self ensureDeviceLocation:@"device"];
}

- (void)verifyReported {
    [self ensureDeviceLocation:@"verify"];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse ||
        manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [manager requestLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    CLLocation *here = locations.lastObject;
    if (!here) return;
    NSString *action = self.pendingDeviceAction;
    self.pendingDeviceAction = nil;
    if ([action isEqual:@"verify"]) {
        CLLocation *wanted = [[CLLocation alloc] initWithLatitude:self.store.coordinate.latitude
                                                        longitude:self.store.coordinate.longitude];
        self.statusLabel.text = [NSString stringWithFormat:SBUIText(@"location.verified"),
                                                           here.coordinate.latitude, here.coordinate.longitude,
                                                           [here distanceFromLocation:wanted]];
        return;
    }
    if ([action isEqual:@"device"]) {
        [self showCoordinate:here.coordinate title:SBUIText(@"location.devicePlace")];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    (void)manager;
    [self showError:error];
}

@end

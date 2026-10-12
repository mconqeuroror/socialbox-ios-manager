#import "RBXLocationPickerViewController.h"
#import "RBXLocationDraft.h"
#import "RBXCatalogPickerViewController.h"
#import "RBXAppearance.h"
#import <MapKit/MapKit.h>

@interface RBXLocationPickerViewController () <UITextFieldDelegate, MKMapViewDelegate>
@property(nonatomic,copy) NSDictionary *catalog;
@property(nonatomic,copy) NSString *country;
@property(nonatomic,copy) NSString *proxyCountry;
@property(nonatomic,copy) NSString *observedCountry;
@property(nonatomic,copy) NSString *latitude;
@property(nonatomic,copy) NSString *longitude;
@property(nonatomic) BOOL locked;
@property(nonatomic) BOOL completed;
@property(nonatomic,copy) void (^selection)(NSDictionary *);
@property(nonatomic,strong) MKMapView *map;
@property(nonatomic,strong) UIScrollView *contentScroll;
@property(nonatomic,strong) UITextField *searchField;
@property(nonatomic,strong) UILabel *locationLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *mapStatusLabel;
@property(nonatomic) NSUInteger mapLoadRevision;
@property(nonatomic) BOOL mapTilesFinished;
@property(nonatomic,strong) UIButton *applyButton;
@property(nonatomic,copy) NSDictionary *draft;
@end

@implementation RBXLocationPickerViewController
- (instancetype)initWithCatalog:(NSDictionary *)catalog country:(NSString *)country
                       latitude:(NSString *)latitude longitude:(NSString *)longitude
                   proxyCountry:(NSString *)proxyCountry observedCountry:(NSString *)observedCountry
                         locked:(BOOL)locked selection:(void (^)(NSDictionary *))selection {
    if ((self=[super initWithNibName:nil bundle:nil])) {
        _catalog=[catalog copy]; _country=[country.uppercaseString copy];
        _latitude=[latitude copy]; _longitude=[longitude copy];
        _proxyCountry=[proxyCountry.uppercaseString copy]; _observedCountry=[observedCountry.uppercaseString copy];
        _locked=locked; _selection=[selection copy]; self.title=@"Location preview";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.navigationController.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.backgroundColor=RBXCanvasColor(); self.view.tintColor=RBXAccentColor();
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Cities" style:UIBarButtonItemStylePlain target:self action:@selector(chooseCity)];
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.contentScroll=[UIScrollView new]; self.contentScroll.translatesAutoresizingMaskIntoConstraints=NO;
    self.contentScroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.contentScroll];
    [NSLayoutConstraint activateConstraints:@[
        [self.contentScroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.contentScroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.contentScroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.contentScroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]]];
    UIStackView *stack=[UIStackView new]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=12; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentScroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentScroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentScroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.contentScroll.contentLayoutGuide.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentScroll.contentLayoutGuide.bottomAnchor constant:-8],
        [stack.widthAnchor constraintEqualToAnchor:self.contentScroll.frameLayoutGuide.widthAnchor constant:-32]]];
    self.searchField=[UITextField new]; RBXStyleField(self.searchField);
    self.searchField.placeholder=@"City or latitude, longitude"; self.searchField.delegate=self;
    self.searchField.returnKeyType=UIReturnKeySearch; self.searchField.autocorrectionType=UITextAutocorrectionTypeNo;
    self.searchField.accessibilityIdentifier=@"location.search";
    [stack addArrangedSubview:self.searchField];
    self.map=[MKMapView new]; self.map.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.map.delegate=self;
    self.map.showsUserLocation=NO; self.map.showsCompass=YES;
    self.map.pointOfInterestFilter=MKPointOfInterestFilter.filterExcludingAllCategories;
    self.map.layer.cornerRadius=22; self.map.clipsToBounds=YES;
    self.map.accessibilityLabel=@"Draft location map. Tap to place a pin near a supported city.";
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    tap.cancelsTouchesInView=NO; [self.map addGestureRecognizer:tap];
    [stack addArrangedSubview:self.map];
    // Keep the map and explanatory text intact when the keyboard reduces the
    // viewport. The content scrolls instead of squeezing labels or hiding it.
    [self.map.heightAnchor constraintEqualToAnchor:self.map.widthAnchor multiplier:.60].active=YES;
    self.mapStatusLabel=RBXLabel(@"Loading map tiles… Coordinates remain available.",UIFontTextStyleCaption2,YES);
    self.mapStatusLabel.accessibilityIdentifier=@"location.mapService";
    [stack addArrangedSubview:self.mapStatusLabel];
    UIStackView *card=RBXFormSection(stack,nil,nil); card.spacing=8;
    self.locationLabel=RBXLabel(@"",UIFontTextStyleHeadline,NO); self.locationLabel.accessibilityIdentifier=@"location.selected";
    [card addArrangedSubview:self.locationLabel];
    self.statusLabel=RBXLabel(@"",UIFontTextStyleFootnote,YES); self.statusLabel.accessibilityIdentifier=@"location.validation";
    [card addArrangedSubview:self.statusLabel];
    self.applyButton=[UIButton buttonWithType:UIButtonTypeSystem]; RBXStyleButton(self.applyButton,YES);
    [self.applyButton setTitle:@"Use in draft" forState:UIControlStateNormal];
    self.applyButton.accessibilityIdentifier=@"location.useDraft";
    [self.applyButton addTarget:self action:@selector(applyLocation) forControlEvents:UIControlEventTouchUpInside];
    [card addArrangedSubview:self.applyButton];
    UILabel *note=RBXLabel(@"Apple Maps uses SocialBox’s connection, not the selected clone proxy. Tiles need network; city search and coordinates work offline. No physical GPS is read. Use in draft, then Check and Save.",UIFontTextStyleCaption2,YES);
    [stack addArrangedSubview:note];
    [self refreshLocation:YES];
    [self mapViewWillStartLoadingMap:self.map];
}

- (void)mapViewWillStartLoadingMap:(MKMapView *)mapView {
    self.mapTilesFinished=NO;
    NSUInteger revision=++self.mapLoadRevision;
    self.mapStatusLabel.text=@"Loading map tiles… Coordinates remain available.";
    self.mapStatusLabel.textColor=UIColor.secondaryLabelColor;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        typeof(self) self=weakSelf;
        if (!self||self.completed||self.mapTilesFinished||revision!=self.mapLoadRevision) return;
        self.mapStatusLabel.text=@"Map tiles are taking longer to load. Use city search or coordinates while offline.";
        self.mapStatusLabel.textColor=[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
    });
}
- (void)mapViewDidFailLoadingMap:(MKMapView *)mapView withError:(NSError *)error {
    if (self.completed) return;
    ++self.mapLoadRevision; self.mapTilesFinished=NO;
    self.mapStatusLabel.text=@"Map tiles unavailable. Search a city or enter coordinates; your draft is kept.";
    self.mapStatusLabel.textColor=[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
}
- (void)mapViewDidFinishRenderingMap:(MKMapView *)mapView fullyRendered:(BOOL)fullyRendered {
    if (!fullyRendered||self.completed) return;
    ++self.mapLoadRevision; self.mapTilesFinished=YES;
    self.mapStatusLabel.text=@"Map tiles loaded · location preview only";
    self.mapStatusLabel.textColor=UIColor.secondaryLabelColor;
}
- (void)refreshLocation:(BOOL)center {
    self.draft=RBXLocationDraft(self.catalog,self.country,self.latitude,self.longitude,self.proxyCountry,self.observedCountry,self.locked);
    BOOL valid=[self.draft[@"valid"] boolValue];
    self.applyButton.enabled=valid&&!self.completed;
    self.statusLabel.text=self.draft[@"reason"];
    self.statusLabel.textColor=self.locked ? [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1] : valid ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
    NSString *city=[self.draft[@"city"] length] ? self.draft[@"city"] : @"Unsupported location";
    self.locationLabel.text=[NSString stringWithFormat:@"%@ · %@\n%@, %@",city,self.country,self.latitude ?: @"—",self.longitude ?: @"—"];
    double lat=0,lon=0;
    [self.map removeAnnotations:self.map.annotations];
    if (RBXLocationNumber(self.latitude,&lat)&&RBXLocationNumber(self.longitude,&lon)&&fabs(lat)<=90&&fabs(lon)<=180) {
        MKPointAnnotation *pin=[MKPointAnnotation new]; pin.coordinate=CLLocationCoordinate2DMake(lat,lon); pin.title=city;
        [self.map addAnnotation:pin];
        if (center) [self.map setRegion:MKCoordinateRegionMake(pin.coordinate,MKCoordinateSpanMake(.10,.10)) animated:NO];
    }
}
- (void)selectLatitude:(NSString *)latitude longitude:(NSString *)longitude {
    if (self.completed) return;
    self.latitude=latitude; self.longitude=longitude; [self refreshLocation:YES];
}
- (void)mapTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateEnded||self.completed) return;
    [self.view endEditing:YES];
    CLLocationCoordinate2D point=[self.map convertPoint:[gesture locationInView:self.map] toCoordinateFromView:self.map];
    self.latitude=[NSString stringWithFormat:@"%.6f",point.latitude]; self.longitude=[NSString stringWithFormat:@"%.6f",point.longitude];
    [self refreshLocation:NO];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    NSString *query=[textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *coordinates=[query componentsSeparatedByString:@","];
    if (coordinates.count==2)
        [self selectLatitude:coordinates[0] longitude:coordinates[1]];
    else [self chooseCity];
    return YES;
}
- (void)chooseCity {
    if (self.completed||self.presentedViewController) return;
    NSMutableArray *options=[NSMutableArray array];
    for (NSDictionary *city in self.catalog[@"countryCities"][self.country] ?: @[])
        if ([city[@"city"] length]&&[city[@"timezone"] length]) [options addObject:@{@"title":city[@"city"],@"value":city[@"city"],@"subtitle":city[@"timezone"],@"group":self.country}];
    __weak typeof(self) weakSelf=self;
    RBXCatalogPickerViewController *picker=[[RBXCatalogPickerViewController alloc] initWithTitle:@"Supported cities" options:options selectedValue:self.draft[@"city"] selection:^(NSString *value) {
        typeof(self) self=weakSelf; if (!self||self.completed) return;
        for (NSDictionary *city in self.catalog[@"countryCities"][self.country] ?: @[]) if ([city[@"city"] isEqual:value]) {
            self.searchField.text=@""; [self selectLatitude:[city[@"lat"] description] longitude:[city[@"lon"] description]]; break;
        }
    }];
    picker.explanation=@"Only catalog cities in this draft’s country are supported. Choosing a city updates the map preview; Use in draft is still required.";
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker]; RBXStyleNavigation(navigation);
    navigation.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    [self presentViewController:navigation animated:YES completion:^{
        if (self.searchField.text.length&&[self.searchField.text rangeOfString:@","].location==NSNotFound) {
            picker.search.searchBar.text=self.searchField.text; [picker updateSearchResultsForSearchController:picker.search];
        }
    }];
}
- (void)applyLocation {
    if (self.completed) return;
    [self refreshLocation:NO];
    if (![self.draft[@"valid"] boolValue]) return;
    self.completed=YES; self.applyButton.enabled=NO;
    if (self.selection) self.selection(self.draft);
    self.selection=nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)cancel {
    self.completed=YES; self.selection=nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

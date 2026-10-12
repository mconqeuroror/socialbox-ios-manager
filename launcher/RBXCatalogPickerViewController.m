#import "RBXCatalogPickerViewController.h"
#import "RBXAppearance.h"

@interface RBXCatalogPickerViewController ()
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *options;
@property(nonatomic, copy, readwrite) NSString *selectedValue;
@property(nonatomic, strong, readwrite) UISearchController *search;
@property(nonatomic, copy) NSArray<NSString *> *groups;
@property(nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *visibleOptions;
@property(nonatomic, copy) void (^selection)(NSString *);
@property(nonatomic) BOOL completed;
@end

@implementation RBXCatalogPickerViewController
- (instancetype)initWithTitle:(NSString *)title options:(NSArray<NSDictionary *> *)options
               selectedValue:(NSString *)selectedValue selection:(void (^)(NSString *))selection {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = title;
        NSMutableArray *checked = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (id item in options) {
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"title"] isKindOfClass:NSString.class] ||
                ![item[@"value"] isKindOfClass:NSString.class] || ![item[@"title"] length] ||
                ![item[@"value"] length] || [seen containsObject:item[@"value"]]) continue;
            NSMutableDictionary *option = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"title",@"value",@"subtitle",@"group",@"searchTerms"])
                if ([item[key] isKindOfClass:NSString.class]) option[key] = [item[key] copy];
            [checked addObject:[option copy]]; [seen addObject:option[@"value"]];
        }
        _options = [checked copy];
        _selectedValue = [selectedValue copy];
        _selection = [selection copy];
        _explanation = @"Select a value for this draft. Review and check the complete identity before saving.";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = RBXAccentColor();
    self.tableView.backgroundColor = RBXCanvasColor();
    self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.traitCollection);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = [@"Search " stringByAppendingString:self.title.lowercaseString];
    self.search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.search.searchBar.accessibilityIdentifier = @"catalog.search";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self updateSearchResultsForSearchController:self.search];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.tableView.traitCollection);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.isViewLoaded && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        self.tableView.backgroundView = RBXWorkspaceBackgroundView(self.tableView.traitCollection);
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *groups = [NSMutableArray array];
    NSMutableArray *sections = [NSMutableArray array];
    for (NSDictionary *option in self.options) {
        NSString *text = [@[option[@"title"],option[@"value"],option[@"subtitle"] ?: @"",option[@"group"] ?: @"",option[@"searchTerms"] ?: @""] componentsJoinedByString:@" "];
        if (query.length && [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) continue;
        NSString *group = option[@"group"] ?: @"";
        NSUInteger index = [groups indexOfObject:group];
        if (index == NSNotFound) { [groups addObject:group]; [sections addObject:[NSMutableArray array]]; index = groups.count-1; }
        [sections[index] addObject:option];
    }
    self.groups = groups;
    self.visibleOptions = sections;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return MAX((NSUInteger)1,self.groups.count); }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section < (NSInteger)self.visibleOptions.count ? self.visibleOptions[section].count : 0;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section < (NSInteger)self.groups.count && [self.groups[section] length] ? self.groups[section] : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.groups.count) return @"No matching choices. Clear the search or try another name or code.";
    return section == (NSInteger)self.groups.count-1 ? self.explanation : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *option = self.visibleOptions[path.section][path.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = RBXCardColor();
    cell.textLabel.text = option[@"title"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.numberOfLines = 0; cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.text = option[@"subtitle"];
    cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = [option[@"value"] isEqual:self.selectedValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier = [@"catalog.option." stringByAppendingString:option[@"value"]];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.completed || path.section < 0 || path.section >= (NSInteger)self.visibleOptions.count ||
        path.row < 0 || path.row >= (NSInteger)self.visibleOptions[path.section].count) return;
    self.completed = YES;
    NSString *value = self.visibleOptions[path.section][path.row][@"value"];
    self.selectedValue = value;
    [tableView reloadData];
    if (self.selection) self.selection(value);
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)cancel {
    self.completed = YES;
    self.selection = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

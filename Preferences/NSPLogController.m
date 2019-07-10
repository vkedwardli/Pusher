#import "NSPLogController.h"
#import "NSPAppSelectionController.h"

#define SEGMENTED_CONTROL_TAG 673
#define NETWORK_RESPONSE_ITEMS @[@"Any", @"Success", @"No Data", @"Error"]
#define END_RESULT_ITEMS @[@"Any", @"Blocked", @"Pushed"]

#define EXPANDED_TEXT_VIEW_TAG 674

static NSPLogController *logControllerSharedInstance = nil;
static void logsUpdated() {
	if (logControllerSharedInstance && [logControllerSharedInstance isKindOfClass:NSPLogController.class] && [logControllerSharedInstance respondsToSelector:@selector(updateLogAndReload)]) {
		[logControllerSharedInstance updateLogAndReload];
	}
}

static NSDictionary *getLogPreferences() {
	CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFArrayRef keyList = CFPreferencesCopyKeyList(PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	NSDictionary *prefs = @{};
	if (keyList) {
		prefs = (NSDictionary *)CFPreferencesCopyMultiple(keyList, PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		if (!prefs) { prefs = @{}; }
		CFRelease(keyList);
	}
	return prefs;
}

@implementation NSPLogController

- (void)dealloc {
	logControllerSharedInstance = nil;
	[_table release];
	[super dealloc];
}

- (void)showAppFilterTutorial {
	UIWindow *window = [UIApplication sharedApplication].keyWindow;
	UIView *tutorialView = [[UIView alloc] initWithFrame:window.bounds];
	tutorialView.alpha = 0.f;
	tutorialView.backgroundColor = [UIColor colorWithWhite:0.f alpha:0.9f];

	// Label setup
	UILabel *label = [UILabel new];
	label.font = [UIFont fontWithName:@"HelveticaNeue-Thin" size:UIFont.systemFontSize * 1.5f];
	label.textColor = UIColor.whiteColor;
	label.text = @"After using the app filter, you can swipe to delete to unset it and show all apps again.\n\nTap anywhere to continue.";
	label.lineBreakMode = NSLineBreakByWordWrapping;
	label.numberOfLines = 0;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.textAlignment = NSTextAlignmentCenter;
	[tutorialView addSubview:label];

	// Constraints
	[label addConstraint:[NSLayoutConstraint constraintWithItem:label attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:270]];
	[label addConstraint:[NSLayoutConstraint constraintWithItem:label attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:tutorialView.frame.size.height]];
	[label.centerXAnchor constraintEqualToAnchor:label.superview.centerXAnchor].active = YES;
	[label.centerYAnchor constraintEqualToAnchor:label.superview.centerYAnchor].active = YES;

	[window addSubview:tutorialView];
	[UIView animateWithDuration:0.3 animations:^{ tutorialView.alpha = 1.f; }];

	// Add touch action after a second
	UITapGestureRecognizer *tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissTutorial:)];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		// Dismiss gesture
		[tutorialView addGestureRecognizer:tapGestureRecognizer];
	});

	CFStringRef tutorialKeyRef = CFSTR("LogAppFilterTutorialShown");
	CFPreferencesSetValue(tutorialKeyRef, (__bridge CFNumberRef) @YES, PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFRelease(tutorialKeyRef);
}

- (void)dismissTutorial:(UITapGestureRecognizer *)tapGestureRecognizer {
	UIView *tutorialView = tapGestureRecognizer.view;
	[UIView animateWithDuration:0.3 animations:^{ tutorialView.alpha = 0.f; } completion:^(BOOL finished){ [tutorialView removeFromSuperview]; }];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	logControllerSharedInstance = self;
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)logsUpdated, CFSTR(PUSHER_LOG_PREFS_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorCoalesce);

  _appList = [ALApplicationList sharedApplicationList];

	_table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
	[_table registerClass:UITableViewCell.class forCellReuseIdentifier:@"LogCell"];
	_table.delegate = self;
	_table.dataSource = self;
	[self.view addSubview:_table];

	_service = [[self.specifier propertyForKey:@"service"] ?: @"" retain];
	_global = XIS_EMPTY(_service);
	_logKey = [Xstr(@"%@Log", _service) retain];
	_logEnabledKey = [Xstr(@"%@LogEnabled", _service) retain];
	_filteredEndResult = nil;
	_filteredNetworkResponse = nil;
	_filteredAppID = nil;
	_filteredGlobalOnly = NO;

	self.navigationItem.title = [self.specifier propertyForKey:@"label"] ?: @"Log";

	CFPropertyListRef logEnabledRef = CFPreferencesCopyValue((__bridge CFStringRef) _logEnabledKey, PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	_logEnabled = logEnabledRef ? ((__bridge NSNumber *) logEnabledRef).boolValue : YES;

	[self updateLogAndReload];
}

- (void)updateLogEnabled:(UISwitch *)logEnabledSwitch {
	_logEnabled = logEnabledSwitch.isOn;
	CFPreferencesSetValue((__bridge CFStringRef) _logEnabledKey, (__bridge CFNumberRef) @(_logEnabled), PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	notify_post(PUSHER_PREFS_NOTIFICATION);
}

- (void)updateGlobalOnly:(UISwitch *)globalOnlySwitch {
	_filteredGlobalOnly = globalOnlySwitch.isOn;
	[self updateLogAndReload];
}

- (void)updateLogAndReload {
	[self updateLog];
	[_table reloadData];
}

- (void)updateLog {
	NSDictionary *prefs = getLogPreferences();

	if (_sections) {
		[_sections release];
	}
	_sections = [@[
		@"Settings",
		@"Filters"
	] mutableCopy];

	if (_data) {
		[_data release];
	}
	_data = [@{
		_sections[0]: [@[
			@"Logger Enabled",
			@"Clear Existing Logs"
		] mutableCopy],
		_sections[1]: [@[
			@"Network Response",
			@"End Result",
			@"Select an App",
			@"Global Only"
		] mutableCopy]
	} mutableCopy];

	if (_global) {
		// remove enabled switch because global can't be disabled
		[_data[_sections[0]] removeObject:@"Logger Enabled"];
		_logEnabledSwitchRow = -1;
		_clearLogRow = 0;

		_globalOnlyRow = 3;
	} else {
		_logEnabledSwitchRow = 0;
		_clearLogRow = 1;
		// remove global only switch because don't show on individual services
		[_data[_sections[1]] removeObject:@"Global Only"];
		_globalOnlyRow = -1;
	}

	_filterSection = 1;
	_networkResponseRow = 0;
	_endResultFilterRow = 1;
	_appFilterRow = 2;
	// _globalOnlyRow above in _gloabl check

	_firstLogSection = _data.count;
	_expandedIndexPaths = [NSMutableArray new];

	NSArray *prefsLog = nil;
	if (_global && !_filteredGlobalOnly) {
		NSMutableArray *allLogs = [NSMutableArray new];
		for (id key in prefs.allKeys) {
			if (![key isKindOfClass:NSString.class]) { continue; }
			// should be all but just in case change implementation later
			if ([key hasSuffix:@"Log"]) {
				NSString *service = [key substringToIndex:((NSString *) key).length - 3];
				NSArray *serviceLogs = (NSArray *) prefs[key];
				if (!serviceLogs) { continue; }
				for (NSDictionary *logSection in serviceLogs) {
					NSMutableDictionary *newLogSection = [logSection mutableCopy];
					newLogSection[@"service"] = service;
					[allLogs addObject:newLogSection];
				}
			}
		}
		prefsLog = allLogs;
	} else {
		// handles _filteredGlobalOnly because _logKey set to @"Log" which is just global
		prefsLog = prefs[_logKey] ?: @[];
	}

	// sort prefs log by timestamp
	NSSortDescriptor *timestampDescriptor = [[NSSortDescriptor alloc] initWithKey:@"timestamp" ascending:NO];
	prefsLog = [prefsLog sortedArrayUsingDescriptors:@[timestampDescriptor]];

	for (NSDictionary *logSection in prefsLog) {
		NSString *logSectionAppID = logSection[@"appID"];
		// if app filter is on, skip if not same app
		if (_filteredAppID) {
			if (!logSectionAppID || !Xeq(logSectionAppID, _filteredAppID)) { continue; }
		}

		NSString *sectionName = logSection[@"name"];
		if (!sectionName) {
			NSString *appName = @"Unknown App";
			if (logSectionAppID) {
				appName = _appList.applications[logSectionAppID];
			}

			NSDate *timestamp = logSection[@"timestamp"];
			if (timestamp && [timestamp isKindOfClass:NSDate.class]) {
				NSDateFormatter *dateFormatter = [NSDateFormatter new];
				dateFormatter.dateStyle = NSDateFormatterMediumStyle;
				dateFormatter.timeStyle = NSDateFormatterMediumStyle;
				NSString *dateString = [dateFormatter stringFromDate:timestamp];
				sectionName = Xstr(@"%@: %@", appName, dateString);
			} else {
				sectionName = Xstr(@"%@: %@", appName, timestamp);
			}
		}
		// added only if global
		NSString *logSectionService = logSection[@"service"];
		if (logSectionService) {
			if (XIS_EMPTY(logSectionService)) {
				sectionName = Xstr(@"{GLOBAL} %@", sectionName);
			} else {
				sectionName = Xstr(@"[%@] %@", logSectionService, sectionName);
			}
		}
		NSArray *logs = logSection[@"logs"] ?: @[];

		if (_filteredNetworkResponse) {
			BOOL networkResponseFilterPasses = NO;
			NSString *filterLogString = Xstr(@"Network Response: %@", _filteredNetworkResponse);
			for (NSString *log in logs) {
				if ([log containsString:filterLogString]) {
					networkResponseFilterPasses = YES;
					break;
				}
			}
			if (!networkResponseFilterPasses) { continue; }
		}
		if (_filteredEndResult) {
			BOOL shouldContainPushed = Xeq(_filteredEndResult, END_RESULT_ITEMS[2]);
			BOOL containsPushed = [logs containsObject:END_RESULT_ITEMS[2]];
			if (shouldContainPushed != containsPushed) { continue; }
		}

		[_sections addObject:sectionName];
		_data[sectionName] = [logs retain];
	}
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.section != _filterSection || (indexPath.row != _networkResponseRow && indexPath.row != _endResultFilterRow && indexPath.row != _globalOnlyRow);
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.section == _filterSection && indexPath.row == _appFilterRow;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section == _filterSection && indexPath.row == _appFilterRow && editingStyle == UITableViewCellEditingStyleDelete) {
		_filteredAppID = nil;
		[self updateLogAndReload];
	}
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	// Clear log button
	if (indexPath.section == 0 && indexPath.row == _clearLogRow) {
		if (_global) {
			NSDictionary *prefs = getLogPreferences();
			for (id key in prefs.allKeys) {
				if (![key isKindOfClass:NSString.class]) { continue; }
				// should be all but just in case change implementation later
				if ([key hasSuffix:@"Log"]) {
					CFPreferencesSetValue((__bridge CFStringRef) key, NULL, PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
				}
			}
			CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		} else {
			CFPreferencesSetValue((__bridge CFStringRef) _logKey, NULL, PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
			CFPreferencesSynchronize(PUSHER_LOG_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		}

		int numSections = [self numberOfSectionsInTableView:tableView];
		if (numSections >= _firstLogSection) {
			[tableView beginUpdates];
			[self updateLog];
			[tableView deleteSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(_firstLogSection, numSections - _firstLogSection)] withRowAnimation:UITableViewRowAnimationAutomatic];
			[tableView endUpdates];
		}
	} else if (indexPath.section == _filterSection && indexPath.row == _appFilterRow) {
		// app filter
		NSPAppSelectionController *appSelectionController = [NSPAppSelectionController new];
		[appSelectionController setCallback:^(id appID) {
			_filteredAppID = [appID copy];
			[self updateLogAndReload];
			CFStringRef tutorialKeyRef = CFSTR("LogAppFilterTutorialShown");
			CFPropertyListRef tutorialShownRef = CFPreferencesCopyValue(tutorialKeyRef, PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
			CFRelease(tutorialKeyRef);
			BOOL tutorialShown = tutorialShownRef ? ((__bridge NSNumber *) tutorialShownRef).boolValue : NO;
			if (!tutorialShown) {
				[self showAppFilterTutorial];
			}
		}];
		appSelectionController.navItemTitle = @"Select an App";
		appSelectionController.selectingMultiple = NO;
		if (_filteredAppID) {
			appSelectionController.selectedAppIDs = [@[_filteredAppID] mutableCopy];
		}
		[self.navigationController pushViewController:appSelectionController animated:YES];
	} else if (indexPath.section >= _firstLogSection) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
		BOOL expanded = [_expandedIndexPaths containsObject:indexPath];
		// use this instead of cell.textLabel.text because may be expanded and have text in uitextview not label
		NSString *text = _data[_sections[indexPath.section]][indexPath.row];

		// only add expand / collapse option if currently expanded or if it is being truncated
		UITableViewCell *cell = [self tableView:tableView cellForRowAtIndexPath:indexPath];
		CGSize textSize = [text sizeWithAttributes:@{NSFontAttributeName: cell.textLabel.font}];
		BOOL isTruncated = textSize.width + 30 > cell.contentView.bounds.size.width;
		if (expanded || isTruncated) {
			[alert addAction:[UIAlertAction actionWithTitle:(expanded ? @"Collapse" : @"Expand") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
				if (expanded) {
					[_expandedIndexPaths removeObject:indexPath];
				} else {
					[_expandedIndexPaths addObject:indexPath];
				}
				[tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
			}]];
		}
		[alert addAction:[UIAlertAction actionWithTitle:@"Copy to Clipboard" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			UIPasteboard.generalPasteboard.string = text;
		}]];
		[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return _sections[section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return ((NSArray *) _data[_sections[section]]).count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return _sections.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LogCell" forIndexPath:indexPath];

	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.accessoryView = nil;
	cell.imageView.image = nil;
	// cell.textLabel.numberOfLines = 1;
	// cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
	cell.textLabel.text = nil;
	cell.textLabel.textColor = nil;

	UITextView *expandedTextView = [cell.contentView viewWithTag:EXPANDED_TEXT_VIEW_TAG];
	if (expandedTextView) {
		[expandedTextView removeFromSuperview];
	}

	UIView *segmentedControlView = [cell.contentView viewWithTag:SEGMENTED_CONTROL_TAG];
	if (segmentedControlView) {
		[segmentedControlView removeFromSuperview];
	}

	if (indexPath.section != _filterSection || (indexPath.row != _networkResponseRow && indexPath.row != _endResultFilterRow)) {
		cell.textLabel.text = _data[_sections[indexPath.section]][indexPath.row];
	}

	if (indexPath.section == _filterSection) {
		if (indexPath.row == _networkResponseRow || indexPath.row == _endResultFilterRow) {
			BOOL isNetworkResponse = indexPath.row == _networkResponseRow;
			UISegmentedControl *segmentedControl = nil;
			if (isNetworkResponse) {
				segmentedControl = [[UISegmentedControl alloc] initWithItems:NETWORK_RESPONSE_ITEMS];
				segmentedControl.selectedSegmentIndex = _filteredNetworkResponse ? [NETWORK_RESPONSE_ITEMS indexOfObject:_filteredNetworkResponse] : 0;
				[segmentedControl addTarget:self action:@selector(networkResponseFilterUpdated:) forControlEvents:UIControlEventValueChanged];
			} else {
				segmentedControl = [[UISegmentedControl alloc] initWithItems:END_RESULT_ITEMS];
				segmentedControl.selectedSegmentIndex = _filteredEndResult ? [END_RESULT_ITEMS indexOfObject:_filteredEndResult] : 0;
				[segmentedControl addTarget:self action:@selector(endResultFilterUpdated:) forControlEvents:UIControlEventValueChanged];
			}
			segmentedControl.tag = SEGMENTED_CONTROL_TAG;
			segmentedControl.apportionsSegmentWidthsByContent = NO;
			[cell.contentView addSubview:segmentedControl];

			segmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
			[segmentedControl.topAnchor constraintEqualToAnchor:segmentedControl.superview.topAnchor constant:5].active = YES;
			[segmentedControl.bottomAnchor constraintEqualToAnchor:segmentedControl.superview.bottomAnchor constant:-5].active = YES;
			[segmentedControl.leadingAnchor constraintEqualToAnchor:segmentedControl.superview.leadingAnchor constant:5].active = YES;
			[segmentedControl.trailingAnchor constraintEqualToAnchor:segmentedControl.superview.trailingAnchor constant:-5].active = YES;
			[segmentedControl.centerXAnchor constraintEqualToAnchor:segmentedControl.superview.centerXAnchor].active = YES;
			[segmentedControl.centerYAnchor constraintEqualToAnchor:segmentedControl.superview.centerYAnchor].active = YES;
		} else if (indexPath.row == _appFilterRow) {
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			if (_filteredAppID) {
				cell.textLabel.text = Xstr(@"App Filter: %@", _appList.applications[_filteredAppID]);
				cell.imageView.image = [_appList iconOfSize:ALApplicationIconSizeSmall forDisplayIdentifier:_filteredAppID];
			}
		} else if (indexPath.row == _globalOnlyRow) {
			UISwitch *globalOnlySwitch = [UISwitch new];
			globalOnlySwitch.on = _filteredGlobalOnly;
			[globalOnlySwitch addTarget:self action:@selector(updateGlobalOnly:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryView = globalOnlySwitch;
		}

		return cell;
	}

	BOOL expanded = [_expandedIndexPaths containsObject:indexPath];
	if (expanded) {
		// cell.textLabel.numberOfLines = 0;
		// cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
		expandedTextView = [UITextView new];
		expandedTextView.tag = EXPANDED_TEXT_VIEW_TAG;
		expandedTextView.editable = NO;
		expandedTextView.text = cell.textLabel.text;
		expandedTextView.font = cell.textLabel.font;
		cell.textLabel.text = nil;
		[cell.contentView addSubview:expandedTextView];

		CGSize textSize = [expandedTextView.text boundingRectWithSize:CGSizeMake(cell.contentView.bounds.size.width, MAXFLOAT) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: expandedTextView.font} context:nil].size;

		CGFloat minHeight = 50;
		CGFloat maxHeight = UIScreen.mainScreen.bounds.size.height / 2;
		CGFloat height = textSize.height > maxHeight ? maxHeight : (textSize.height < minHeight ? minHeight : textSize.height);

		expandedTextView.translatesAutoresizingMaskIntoConstraints = NO;
		[expandedTextView.topAnchor constraintEqualToAnchor:expandedTextView.superview.topAnchor constant:10].active = YES;
		[expandedTextView.bottomAnchor constraintEqualToAnchor:expandedTextView.superview.bottomAnchor constant:-10].active = YES;
		[expandedTextView.leadingAnchor constraintEqualToAnchor:expandedTextView.superview.leadingAnchor constant:10].active = YES;
		[expandedTextView.trailingAnchor constraintEqualToAnchor:expandedTextView.superview.trailingAnchor constant:-10].active = YES;
		[expandedTextView addConstraint:[NSLayoutConstraint constraintWithItem:expandedTextView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:height]];
	}

	CGSize textSize = [cell.textLabel.text sizeWithAttributes:@{NSFontAttributeName: cell.textLabel.font}];
	BOOL isTruncated = textSize.width + 30 > cell.contentView.bounds.size.width;
	if (indexPath.section >= _firstLogSection && !expanded && isTruncated) {
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}

	if (indexPath.section == 0 && indexPath.row == _clearLogRow) {
		cell.textLabel.textColor = [UIColor colorWithRed:0.0 green:122/255.0 blue:255/255.0 alpha:1.0];
	}

	if (indexPath.section == 0 && indexPath.row == _logEnabledSwitchRow) {
		UISwitch *logEnabledSwitch = [UISwitch new];
		logEnabledSwitch.on = _logEnabled;
		[logEnabledSwitch addTarget:self action:@selector(updateLogEnabled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = logEnabledSwitch;
	}

	return cell;
}

- (void)networkResponseFilterUpdated:(UISegmentedControl *)segmentedControl {
	int idx = segmentedControl.selectedSegmentIndex;
	if (idx == 0) { // any
		_filteredNetworkResponse = nil;
	} else {
		_filteredNetworkResponse = NETWORK_RESPONSE_ITEMS[idx];
	}
	[self updateLogAndReload];
}

- (void)endResultFilterUpdated:(UISegmentedControl *)segmentedControl {
	int idx = segmentedControl.selectedSegmentIndex;
	if (idx == 0) { // any
		_filteredEndResult = nil;
	} else {
		_filteredEndResult = END_RESULT_ITEMS[idx];
	}
	[self updateLogAndReload];
}

@end

#import "global.h"
#import <Custom/defines.h>

#import <BulletinBoard/BBBulletin.h>
#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBApplicationController.h>

@interface BBBulletin (Pusher)
@property (nonatomic, readonly) bool showsSubtitle;
- (void)sendBulletinToPusher:(BBBulletin *)bulletin;
@end

static BOOL pusherEnabled = YES;
static NSArray *pusherExcludedApps = nil;
static NSString *pusherToken = nil;
static NSString *pusherUser = nil;
static NSString *pusherDevice = nil;

static void pusherPrefsChanged() {
	XLog(@"Reloading prefs");
	NSDictionary *pusherPrefs = [NSDictionary dictionaryWithContentsOfFile:PUSHER_PREFS_FILE];
	id val = pusherPrefs[@"enabled"];
	pusherEnabled = val ? ((NSNumber *) val).boolValue : YES;
	val = [pusherPrefs[@"pushoverToken"] copy];
	pusherToken = val ? val : @"";
	val = [pusherPrefs[@"pushoverUser"] copy];
	pusherUser = val ? val : @"";
	val = [pusherPrefs[@"pushoverDevice"] copy];
	pusherDevice = val ? val : @"";
	// Extract all excluded app IDs
	NSMutableArray *tempPusherExcludedApps = [[NSMutableArray alloc] init];
	for (id key in pusherPrefs.allKeys) {
		if (![key isKindOfClass:NSString.class]) { continue; }
		if ([key hasPrefix:@"ExcludedApp-"]) {
			if (((NSNumber *) pusherPrefs[key]).boolValue) {
				[tempPusherExcludedApps addObject:[key substringFromIndex:12].lowercaseString];
			}
		}
	}
	pusherExcludedApps = [tempPusherExcludedApps copy];
	[tempPusherExcludedApps release];
}

static BOOL pusherPrefsSayNo() {
	return !pusherEnabled
					|| pusherExcludedApps == nil
					|| pusherToken == nil
					|| pusherUser == nil
					|| pusherDevice == nil;
}

%hook BBServer

%new
- (void)sendBulletinToPusher:(BBBulletin *)bulletin {
	if (pusherPrefsSayNo() || bulletin == nil) {
		return;
	}
	// Check if notification within last 5 seconds so we don't send uncleared notifications every respring
	NSDate *fiveSecondsAgo = [[NSDate date] dateByAddingTimeInterval:-5];
	if ((bulletin.date && [bulletin.date compare:fiveSecondsAgo] == NSOrderedAscending)
			|| [pusherExcludedApps containsObject:bulletin.sectionID.lowercaseString]) {
		return;
	}
	SBApplication *app = [[NSClassFromString(@"SBApplicationController") sharedInstance] applicationWithBundleIdentifier:bulletin.sectionID];
	NSString *appName = app && app.displayName && app.displayName.length > 0 ? app.displayName : Xstr(@"Unknown App: %@", bulletin.sectionID);
	NSString *title = Xstr(@"%@%@", appName, (bulletin.title && bulletin.title.length > 0 ? Xstr(@" [%@]", bulletin.title) : @""));
	NSString *message = @"";
	if (bulletin.subtitle && bulletin.subtitle.length > 0) {
		message = bulletin.subtitle;
	}
	message = Xstr(@"%@%@%@", message, (message.length > 0 && bulletin.message && bulletin.message.length > 0 ? @"\n" : @""), bulletin.message ? bulletin.message : @"");
	NSDictionary *userDictionary = @{
		@"token": pusherToken,
		@"user": pusherUser,
		@"title": title,
		@"message": message,
		@"device": pusherDevice
	};
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:userDictionary options:NSJSONWritingPrettyPrinted error:nil];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.pushover.net/1/messages.json"] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	[request setValue:Xstr(@"%lu", jsonData.length) forHTTPHeaderField:@"Content-length"];
	[request setHTTPBody:jsonData];

	//use async way to connect network
	[[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response, NSError *error) {
		if ([data length] > 0 && error == nil) {
			XLog(@"Success");
		} else if ([data length] == 0 && error == nil) {
			XLog(@"No data");
		} else if (error != nil) {
			XLog(@"Error: %@", error);
		} else {
			XLog(@"idk what happened");
		}
	}] resume];
	XLog(@"Pushed %@", appName);
}

// iOS 11?
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned int)arg2 alwaysToLockScreen:(BOOL)arg3 {
	%orig;
	[self sendBulletinToPusher:bulletin];
}

// iOS 12?
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)arg2 {
	%orig;
	[self sendBulletinToPusher:bulletin];
}

%end

%ctor {
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)pusherPrefsChanged, PUSHER_PREFS_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorCoalesce);
	pusherPrefsChanged();
	%init;
}

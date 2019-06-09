#import "global.h"
#import <Custom/defines.h>
#import "NSPTestPush.h"
#import <SystemConfiguration/CaptiveNetwork.h>

@interface UIImage (UIApplicationIconPrivate)
/*
 @param format
    0 - 29x29
    1 - 40x40
    2 - 62x62
    3 - 42x42
    4 - 37x48
    5 - 37x48
    6 - 82x82
    7 - 62x62
    8 - 20x20
    9 - 37x48
    10 - 37x48
    11 - 122x122
    12 - 58x58
 */
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format;
@end

static BOOL pusherEnabled = NO;
static int pusherWhenToPush = PUSHER_WHEN_TO_PUSH_LOCKED;
static BOOL pusherOnWiFiOnly = NO;
static NSArray *globalBlacklist = nil;
static NSMutableDictionary *pusherEnabledServices = nil;
static NSMutableDictionary *pusherServicePrefs = nil;

static BBServer *bbServerInstance = nil;

static NSMutableArray *recentNotificationTitles = [NSMutableArray new];

// Make all app IDs lowercase in case some library I use starts messing with the case
static NSArray *getPusherBlacklist(NSDictionary *prefs, NSString *prefix) {
	// Extract all blacklisted app IDs
	NSMutableArray *blacklist = [NSMutableArray new];
	for (id key in prefs.allKeys) {
		if (![key isKindOfClass:NSString.class]) { continue; }
		if ([key hasPrefix:prefix]) {
			if (((NSNumber *) prefs[key]).boolValue) {
				[blacklist addObject:[key substringFromIndex:prefix.length].lowercaseString];
			}
		}
	}
	NSArray *ret = [blacklist copy];
	[blacklist release];
	return ret;
}

static NSString *getServiceURL(NSString *service, NSDictionary *options) {
	if (Xeq(service, PUSHER_SERVICE_PUSHOVER)) {
		return PUSHER_SERVICE_PUSHOVER_URL;
	} else if (Xeq(service, PUSHER_SERVICE_PUSHBULLET)) {
		return PUSHER_SERVICE_PUSHBULLET_URL;
	} else if (Xeq(service, PUSHER_SERVICE_IFTTT)) {
		return [PUSHER_SERVICE_IFTTT_URL stringByReplacingOccurrencesOfString:@"REPLACE_EVENT_NAME" withString:options[@"eventName"]];
	}
	return @"";
}

static NSString *getServiceAppID(NSString *service) {
	if (Xeq(service, PUSHER_SERVICE_PUSHOVER)) {
		return PUSHER_SERVICE_PUSHOVER_APP_ID;
	} else if (Xeq(service, PUSHER_SERVICE_PUSHBULLET)) {
		return PUSHER_SERVICE_PUSHBULLET_APP_ID;
	}
	return @"";
}

static PusherAuthorizationType getServiceAuthType(NSString *service, NSDictionary *servicePrefs) {
	if (servicePrefs[@"isCustomService"] && ((NSNumber *) servicePrefs[@"isCustomService"]).boolValue) {
		NSNumber *authMethod = servicePrefs[@"authenticationMethod"];
		if (!authMethod) {
			return PusherAuthorizationTypeNone;
		}
		switch (authMethod.intValue) {
			case 1:
				return PusherAuthorizationTypeHeader;
			case 2:
				return PusherAuthorizationTypeCredentials;
			default:
				return PusherAuthorizationTypeNone;
		}
	} else if (Xeq(service, PUSHER_SERVICE_PUSHOVER)) {
		return PusherAuthorizationTypeCredentials;
	} else if (Xeq(service, PUSHER_SERVICE_PUSHBULLET)) {
		return PusherAuthorizationTypeHeader;
	}
	return PusherAuthorizationTypeReplaceKey; // ifttt key
}

static void pusherPrefsChanged() {
	XLog(@"Reloading prefs");

	CFArrayRef keyList = CFPreferencesCopyKeyList(PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	NSDictionary *prefs = @{};
	if (keyList) {
		prefs = (NSDictionary *)CFPreferencesCopyMultiple(keyList, PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
		if (!prefs) { prefs = @{}; }
		CFRelease(keyList);
	}

	id val = prefs[@"Enabled"];
	pusherEnabled = val ? ((NSNumber *) val).boolValue : YES;
	val = prefs[@"WhenToPush"];
	pusherWhenToPush = val ? ((NSNumber *) val).intValue : PUSHER_WHEN_TO_PUSH_LOCKED;
	val = prefs[@"OnWiFiOnly"];
	pusherOnWiFiOnly = val ? ((NSNumber *) val).boolValue : NO;
	globalBlacklist = getPusherBlacklist(prefs, NSPPreferenceGlobalBLPrefix);

	if (pusherEnabledServices == nil) {
		pusherEnabledServices = [NSMutableDictionary new];
	}
	if (pusherServicePrefs == nil) {
		pusherServicePrefs = [NSMutableDictionary new];
	}

	NSDictionary *customServices = prefs[NSPPreferenceCustomServicesKey];
	for (NSString *service in customServices.allKeys) {
		NSDictionary *customService = customServices[service];
		NSMutableDictionary *servicePrefs = [customService mutableCopy];

		servicePrefs[@"isCustomService"] = @YES;
		servicePrefs[@"blacklist"] = getPusherBlacklist(prefs, NSPPreferenceCustomServiceBLPrefix(service));

		NSString *customAppsKey = NSPPreferenceCustomServiceCustomAppsKey(service);

		// custom apps
		NSDictionary *prefCustomApps = (NSDictionary *) prefs[customAppsKey] ?: @{};
		NSMutableDictionary *customApps = [NSMutableDictionary new];
		for (NSString *customAppID in prefCustomApps.allKeys) {
			NSDictionary *customAppPrefs = prefCustomApps[customAppID];
			// skip if custom app is disabled, default enabled so ignore bool check if key doesn't exist
			if (customAppPrefs[@"enabled"] && !((NSNumber *) customAppPrefs[@"enabled"]).boolValue) {
				continue;
			}
			customApps[customAppID] = [customAppPrefs copy];
		}

		servicePrefs[@"customApps"] = [customApps copy];

		pusherServicePrefs[service] = [servicePrefs copy];

		// default is service disabled
		if (customService[@"Enabled"] == nil || !((NSNumber *) customService[@"Enabled"]).boolValue) {
			// skip if disabled
			[pusherEnabledServices removeObjectForKey:service];
		} else {
			pusherEnabledServices[service] = pusherServicePrefs[service];
		}
	}

	for (NSString *service in BUILTIN_PUSHER_SERVICES) {
		NSMutableDictionary *servicePrefs = [NSMutableDictionary new];

		NSString *blacklistPrefix = Xstr(@"%@BL-", service);
		NSString *tokenKey = Xstr(@"%@Token", service);
		NSString *userKey = Xstr(@"%@User", service);
		NSString *keyKey = Xstr(@"%@Key", service);
		NSString *devicesKey = Xstr(@"%@Devices", service);
		NSString *soundsKey = Xstr(@"%@Sounds", service);
		NSString *eventNameKey = Xstr(@"%@EventName", service);
		NSString *dateFormatKey = Xstr(@"%@DateFormat", service);
		NSString *customAppsKey = Xstr(@"%@CustomApps", service);

		servicePrefs[@"blacklist"] = getPusherBlacklist(prefs, blacklistPrefix);
		val = prefs[tokenKey];
		servicePrefs[@"token"] = [(val ?: @"") copy];
		val = prefs[userKey];
		servicePrefs[@"user"] = [(val ?: @"") copy];
		val = prefs[keyKey];
		servicePrefs[@"key"] = [(val ?: @"") copy];
		val = prefs[eventNameKey];
		NSString *eventName = [(val ?: @"") copy];
		val = prefs[dateFormatKey];
		servicePrefs[@"dateFormat"] = [(val ?: @"") copy];
		servicePrefs[@"url"] = getServiceURL(service, @{ @"eventName": eventName });

		if (Xeq(service, PUSHER_SERVICE_IFTTT)) {
			NSString *includeIconKey = Xstr(@"%@IncludeIcon", service);
			servicePrefs[@"includeIcon"] = prefs[includeIconKey] ?: @NO;
		}

		// devices
		NSArray *devices = prefs[devicesKey] ?: @[];
		NSMutableArray *enabledDevices = [NSMutableArray new];
		for (NSDictionary *device in devices) {
			if (((NSNumber *) device[@"enabled"]).boolValue) {
				[enabledDevices addObject:device];
			}
		}
		servicePrefs[@"devices"] = [enabledDevices retain];
		// [enabledDevices release];
		// [devices release];

		// sounds
		NSArray *sounds = prefs[soundsKey] ?: @[];
		NSMutableArray *enabledSounds = [NSMutableArray new];
		for (NSDictionary *sound in sounds) {
			if (((NSNumber *) sound[@"enabled"]).boolValue) {
				[enabledSounds addObject:sound[@"id"]];
			}
		}
		servicePrefs[@"sounds"] = [enabledSounds retain];

		// custom apps
		NSDictionary *prefCustomApps = (NSDictionary *)prefs[customAppsKey] ?: @{};
		NSMutableDictionary *customApps = [NSMutableDictionary new];
		for (NSString *customAppID in prefCustomApps.allKeys) {
			NSDictionary *customAppPrefs = prefCustomApps[customAppID];
			// skip if custom app is disabled, default enabled so ignore bool check if key doesn't exist
			if (customAppPrefs[@"enabled"] && !((NSNumber *) customAppPrefs[@"enabled"]).boolValue) {
				continue;
			}

			NSArray *customAppDevices = customAppPrefs[@"devices"] ?: @{};
			NSMutableArray *customAppEnabledDevices = [NSMutableArray new];
			for (NSDictionary *customAppDevice in customAppDevices) {
				if (((NSNumber *) customAppDevice[@"enabled"]).boolValue) {
					[customAppEnabledDevices addObject:customAppDevice];
				}
			}

			NSArray *customAppSounds = customAppPrefs[@"sounds"] ?: @{};
			NSMutableArray *customAppEnabledSounds = [NSMutableArray new];
			for (NSDictionary *customAppSound in customAppSounds) {
				if (((NSNumber *) customAppSound[@"enabled"]).boolValue) {
					[customAppEnabledSounds addObject:customAppSound[@"id"]];
				}
			}

			NSString *customAppEventName = [(customAppPrefs[@"eventName"] ?: eventName) retain];
			NSString *customAppUrl = getServiceURL(service, @{ @"eventName": customAppEventName });

			NSMutableDictionary *customAppIDPref = [@{
				@"devices": [customAppEnabledDevices retain],
				@"sounds": [customAppEnabledSounds retain]
			} mutableCopy];

			if (!Xeq(customAppUrl, servicePrefs[@"url"])) {
				customAppIDPref[@"url"] = customAppUrl;
			}

			if (Xeq(service, PUSHER_SERVICE_IFTTT)) {
				customAppIDPref[@"includeIcon"] = customAppPrefs[@"includeIcon"] ?: @NO;
			}

			customApps[customAppID] = customAppIDPref;
			// [customAppEnabledDevices release];
			// [customAppDevices release];
			// [customAppPrefs release];
		}
		servicePrefs[@"customApps"] = [customApps copy];
		// [customApps release];

		pusherServicePrefs[service] = [servicePrefs copy];

		NSString *enabledKey = Xstr(@"%@Enabled", service);
		// default is service disabled
		if (prefs[enabledKey] == nil || !((NSNumber *) prefs[enabledKey]).boolValue) {
			// skip if disabled
			[pusherEnabledServices removeObjectForKey:service];
		} else {
			pusherEnabledServices[service] = pusherServicePrefs[service];
		}
	}

	XLog(@"Reloaded");
}

static BOOL prefsSayNo() {
	BOOL deviceIsLocked = ((SBLockScreenManager *) [%c(SBLockScreenManager) sharedInstance]).isUILocked;
	BOOL onWifi = [[%c(SBWiFiManager) sharedInstance] currentNetworkName] != nil;
	if (!pusherEnabled
				|| (pusherOnWiFiOnly && !onWifi)
				|| (pusherWhenToPush == PUSHER_WHEN_TO_PUSH_LOCKED && !deviceIsLocked)
				|| (pusherWhenToPush == PUSHER_WHEN_TO_PUSH_UNLOCKED && deviceIsLocked)
				|| globalBlacklist == nil || ![globalBlacklist isKindOfClass:NSArray.class]) {
		return YES;
	}
	for (NSString *service in pusherEnabledServices.allKeys) {
		NSDictionary *servicePrefs = pusherEnabledServices[service];
		if (servicePrefs == nil/*
					|| servicePrefs[@"blacklist"] == nil || ![servicePrefs[@"blacklist"] isKindOfClass:NSArray.class]
					|| servicePrefs[@"token"] == nil || ![servicePrefs[@"token"] isKindOfClass:NSString.class] || ((NSString *) servicePrefs[@"token"]).length == 0
					|| servicePrefs[@"user"] == nil || ![servicePrefs[@"user"] isKindOfClass:NSString.class] || ((NSString *) servicePrefs[@"user"]).length == 0
					|| servicePrefs[@"devices"] == nil || ![servicePrefs[@"devices"] isKindOfClass:NSArray.class] // devices can be empty depending on API
					|| servicePrefs[@"url"] == nil || ![servicePrefs[@"url"] isKindOfClass:NSString.class] || ((NSString *) servicePrefs[@"url"]).length == 0
					|| servicePrefs[@"customApps"] == nil || ![servicePrefs[@"customApps"] isKindOfClass:NSDictionary.class]*/) {
			return YES;
		}
		for (id val in servicePrefs.allValues) {
			if (val == nil) {
				return YES;
			}
		}
	}
	return NO;
}

%hook BBServer

%new
+ (BBServer *)pusherSharedInstance {
	return bbServerInstance;
}

- (void)_addObserver:(id)arg1 {
	bbServerInstance = self;
	%orig;
}

%new
- (void)sendBulletinToPusher:(BBBulletin *)bulletin {
	if (bulletin == nil || prefsSayNo()) {
		XLog(@"Prefs said no / bulletin nil: %d", bulletin == nil);
		return;
	}
	// Check if notification within last 5 seconds so we don't send uncleared notifications every respring
	NSDate *fiveSecondsAgo = [[NSDate date] dateByAddingTimeInterval:-5];
	if (bulletin.date && [bulletin.date compare:fiveSecondsAgo] == NSOrderedAscending) {
		return;
	}
	NSString *appID = bulletin.sectionID;
	// Blacklist array contains lowercase app IDs
	if ([globalBlacklist containsObject:appID.lowercaseString]) {
		XLog(@"[Global] Blacklisted");
		return;
	}

	SBApplication *app = [[NSClassFromString(@"SBApplicationController") sharedInstance] applicationWithBundleIdentifier:appID];
	NSString *appName = app && app.displayName && app.displayName.length > 0 ? app.displayName : Xstr(@"Unknown App: %@", appID);
	NSString *title = Xstr(@"%@%@", appName, (bulletin.title && bulletin.title.length > 0 ? Xstr(@": %@", bulletin.title) : @""));
	NSString *message = @"";
	if (bulletin.subtitle && bulletin.subtitle.length > 0) {
		message = bulletin.subtitle;
	}
	message = Xstr(@"%@%@%@", message, (message.length > 0 && bulletin.message && bulletin.message.length > 0 ? @"\n" : @""), bulletin.message ? bulletin.message : @"");

	for (NSString *recentNotificationTitle in recentNotificationTitles) {
		// prevent looping by checking if this title contains any recent titles in format of "App [Previous Title]"
		if (Xeq(title, Xstr(@"%@: %@", appName, recentNotificationTitle))) {
			XLog(@"Prevented loop");
			return;
		}
	}
	// keep array small, looping shouldn't happen after 50 notifications have already passed
	if (recentNotificationTitles.count >= 50) {
		[recentNotificationTitles removeAllObjects];
	}
	[recentNotificationTitles addObject:title];

	for (NSString *service in pusherEnabledServices.allKeys) {
		[self sendToPusherService:service bulletin:bulletin appID:appID appName:appName title:title message:message isTest:NO];
	}
}

%new
- (void)sendToPusherService:(NSString *)service bulletin:(BBBulletin *)bulletin appID:(NSString *)appID appName:(NSString *)appName title:(NSString *)title message:(NSString *)message isTest:(BOOL)isTest {
	if (!isTest && Xeq(appID, getServiceAppID(service))) {
		XLog(@"Prevented loop from same app");
		return;
	}
	NSDictionary *servicePrefs = pusherServicePrefs[service];
	NSArray *serviceBlacklist = servicePrefs[@"blacklist"];
	// Blacklist array contains lowercase app IDs
	if (!isTest && [serviceBlacklist containsObject:appID.lowercaseString]) {
		XLog(@"[S:%@] Blacklisted", service);
		return;
	}
	// Custom app prefs?
	NSDictionary *customApps = servicePrefs[@"customApps"];

	NSArray *devices = servicePrefs[@"devices"];
	if ([customApps.allKeys containsObject:appID] && customApps[appID][@"devices"]) {
		devices = customApps[appID][@"devices"];
	}
	NSArray *sounds = servicePrefs[@"sounds"];
	if ([customApps.allKeys containsObject:appID] && customApps[appID][@"sounds"]) {
		sounds = customApps[appID][@"sounds"];
	}
	NSString *url = servicePrefs[@"url"];
	if ([customApps.allKeys containsObject:appID] && customApps[appID][@"url"]) {
		url = customApps[appID][@"url"];
	}
	NSNumber *includeIcon = servicePrefs[@"includeIcon"] ?: @NO;
	if ([customApps.allKeys containsObject:appID] && customApps[appID][@"includeIcon"]) {
		includeIcon = customApps[appID][@"includeIcon"];
	}
	// Send
	PusherAuthorizationType authType = getServiceAuthType(service, servicePrefs);
	NSDictionary *infoDict = [self getPusherInfoDictionaryForService:service withDictionary:@{
		@"title": title ?: @"",
		@"message": message ?: @"",
		@"devices": devices ?: @[],
		@"sounds": sounds ?: @[],
		@"appName": appName ?: @"",
		@"bulletin": bulletin,
		@"dateFormat": XStrDefault(servicePrefs[@"dateFormat"], @"MMM d, h:mm a"),
		@"includeIcon": includeIcon
	}];
	NSDictionary *credentials = [self getPusherCredentialsForService:service withDictionary:@{
		@"token": servicePrefs[@"token"] ?: @"",
		@"user": servicePrefs[@"user"] ?: @"",
		@"key": servicePrefs[@"key"] ?: @"",
		@"paramName": authType == PusherAuthorizationTypeCredentials ? XStrDefault(servicePrefs[@"paramName"], @"key") : @"",
		@"headerName": authType == PusherAuthorizationTypeHeader ? XStrDefault(servicePrefs[@"paramName"], @"Access-Token") : @""
	}];
	NSString *method = XStrDefault(servicePrefs[@"method"], @"POST");
	[self makePusherRequest:url infoDict:infoDict credentials:credentials authType:authType method:method];
	XLog(@"[S:%@:%d] Pushed %@", service, isTest, appName);
}

%new
- (NSDictionary *)getPusherInfoDictionaryForService:(NSString *)service withDictionary:(NSDictionary *)dictionary {
	NSMutableArray *deviceIDs = [NSMutableArray new];
	for (NSDictionary *device in dictionary[@"devices"]) {
		[deviceIDs addObject:device[@"id"]];
	}
	if (Xeq(service, PUSHER_SERVICE_PUSHOVER)) {
		NSString *combinedDevices = [deviceIDs componentsJoinedByString:@","];
		NSMutableDictionary *pushoverInfoDict = [@{
			@"title": dictionary[@"title"],
			@"message": dictionary[@"message"],
			@"device": combinedDevices
		} mutableCopy];
		NSString *firstSoundID = [dictionary[@"sounds"] firstObject];
		if (firstSoundID) {
			pushoverInfoDict[@"sound"] = firstSoundID;
		}
		return pushoverInfoDict;
	} else if (Xeq(service, PUSHER_SERVICE_PUSHBULLET)) {
		// should always only be one, but just in case
		NSString *firstDevice = [deviceIDs firstObject];
		NSMutableDictionary *pushbulletInfoDict = [@{
			@"type": @"note",
			@"title": dictionary[@"title"],
			@"body": dictionary[@"message"]
		} mutableCopy];
		if (firstDevice) {
			pushbulletInfoDict[@"device_iden"] = firstDevice;
		}
		return pushbulletInfoDict;
	}

	// ifttt and custom services
	BBBulletin *bulletin = dictionary[@"bulletin"];
	// date
	NSDateFormatter *dateFormatter = [NSDateFormatter new];
	[dateFormatter setDateFormat:dictionary[@"dateFormat"]];
	NSString *dateStr = [dateFormatter stringFromDate:bulletin.date];
	[dateFormatter release];

	NSMutableDictionary *data = [@{
		@"appName": dictionary[@"appName"] ?: @"",
		@"appID": bulletin.sectionID ?: @"",
		@"title": bulletin.title ?: @"",
		@"subtitle": bulletin.subtitle ?: @"",
		@"message": bulletin.message ?: @"",
		@"date": dateStr ?: @""
	} mutableCopy];

	if (dictionary[@"includeIcon"] && ((NSNumber *)dictionary[@"includeIcon"]).boolValue) {
		data[@"icon"] = [self base64IconDataForBundleID:bulletin.sectionID];
	}

	if (Xeq(service, PUSHER_SERVICE_IFTTT)) {
		id json = data;
		NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
		if (jsonData) {
			json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
		}
		return @{ @"value1": json };
	}

	return data;
}

%new
- (NSString *)base64IconDataForBundleID:(NSString *)bundleID {
	SBApplicationIcon *icon = [((SBIconController *)[%c(SBIconController) sharedInstance]).model expectedIconForDisplayIdentifier:bundleID];
	UIImage *image = [icon generateIconImage:2];

	NSData *iconData = UIImagePNGRepresentation(image);
	NSString *base64Representation = [iconData base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];

	return base64Representation;
}

%new
- (NSDictionary *)getPusherCredentialsForService:(NSString *)service withDictionary:(NSDictionary *)dictionary {
	if (Xeq(service, PUSHER_SERVICE_PUSHOVER)) {
		return @{
			@"token": dictionary[@"token"],
			@"user": dictionary[@"user"]
		};
	} else if (Xeq(service, PUSHER_SERVICE_PUSHBULLET)) {
		return @{
			@"key": dictionary[@"token"],
			@"headerName": @"Access-Token"
		};
	} else if (Xeq(service, PUSHER_SERVICE_IFTTT)) {
		return @{
			@"key": dictionary[@"key"]
		};
	}

	// custom services
	if (dictionary[@"paramName"] && ((NSString *) dictionary[@"paramName"]).length > 0) {
		return @{
			dictionary[@"paramName"]: dictionary[@"key"]
		};
	} else if (dictionary[@"headerName"] && ((NSString *) dictionary[@"headerName"]).length > 0) {
		return @{
			@"key": dictionary[@"key"],
			@"headerName": dictionary[@"headerName"]
		};
	}

	return @{
		@"key": dictionary[@"key"]
	};
}

%new
- (void)makePusherRequest:(NSString *)urlString infoDict:(NSDictionary *)infoDict credentials:(NSDictionary *)credentials authType:(PusherAuthorizationType)authType method:(NSString *)method {

	NSMutableDictionary *infoDictForRequest = [infoDict mutableCopy];
	if (authType == PusherAuthorizationTypeCredentials) {
		[infoDictForRequest addEntriesFromDictionary:credentials];
	}
	if (authType == PusherAuthorizationTypeReplaceKey) {
		urlString = [urlString stringByReplacingOccurrencesOfString:@"REPLACE_KEY" withString:credentials[@"key"]];
	}

	if (Xeq(method, @"GET")) {
		NSString *parameterString = @"";
		for (NSString *key in infoDictForRequest.allKeys) {
			NSString *value = XStrDefault(infoDictForRequest[key], @"");
			NSString *escapedKey = [[[key stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"] stringByReplacingOccurrencesOfString:@"=" withString:@"%3D"];
			NSString *escapedValue = [[[value stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"] stringByReplacingOccurrencesOfString:@"=" withString:@"%3D"];
			parameterString = Xstr(@"%@%@%@=%@", parameterString, (parameterString.length < 1 ? @"" : @"&"), escapedKey, escapedValue);
		}
		urlString = Xstr(@"%@?%@", urlString, parameterString);
		XLog(@"URL String: %@", urlString);
	}

	NSURL *requestURL = [NSURL URLWithString:urlString];
	if (!requestURL) {
		XLog(@"Invalid URL: %@", urlString);
		return;
	}
	urlString = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];

	[request setHTTPMethod:method];
	if (authType == PusherAuthorizationTypeHeader) {
		[request setValue:credentials[@"key"] forHTTPHeaderField:credentials[@"headerName"]];
	}

	if (Xeq(method, @"POST")) {
		[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
		[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
		NSData *requestData = [NSJSONSerialization dataWithJSONObject:infoDictForRequest options:NSJSONWritingPrettyPrinted error:nil];
		[request setValue:Xstr(@"%lu", requestData.length) forHTTPHeaderField:@"Content-Length"];
		[request setHTTPBody:requestData];
	}

	//use async way to connect network
	[[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		if (data.length && error == nil) {
			XLog(@"Success");
			// XLog(@"data: %@", [[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "]);
		} else if (error) {
			XLog(@"Error: %@", error);
		} else {
			XLog(@"No data");
		}
	}] resume];

}

// iOS 10 & 11
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)arg2 alwaysToLockScreen:(BOOL)arg3 {
	%orig;
	[self sendBulletinToPusher:bulletin];
}

// iOS 12
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)arg2 {
	%orig;
	[self sendBulletinToPusher:bulletin];
}

%end

%ctor {
	CFPreferencesSynchronize(PUSHER_APP_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)pusherPrefsChanged, PUSHER_PREFS_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorCoalesce);
	pusherPrefsChanged();
	%init;
	[NSPTestPush load];
}

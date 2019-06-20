#define kName @"Pusher"

#define PUSHER_PREFS_FILE @"/var/mobile/Library/Preferences/com.noahsaso.pusher.plist"
#define PUSHER_PREFS_NOTIFICATION CFSTR("com.noahsaso.pusher/prefs")

#define PUSHER_APP_ID CFSTR("com.noahsaso.pusher")

#define PUSHER_MESSAGING_CENTER_NAME @"com.noahsaso.pusher/testpush"
#define PUSHER_TEST_PUSH_MESSAGE_NAME @"sendTest"
#import <rocketbootstrap/rocketbootstrap.h>
#import <AppSupport/CPDistributedMessagingCenter.h>

#define NSPPreferenceGlobalBLPrefix @"GlobalBL-"
#define NSPPreferenceSNSPrefix @"SNS-"

#define PUSHER_WHEN_TO_PUSH_LOCKED 0
#define PUSHER_WHEN_TO_PUSH_EITHER 1
#define PUSHER_WHEN_TO_PUSH_UNLOCKED 2

typedef NS_OPTIONS(NSUInteger, BBActualSectionInfoPushSettings) {
	BBActualSectionInfoPushSettingsBadges = 1 << 3, // was 0
	BBActualSectionInfoPushSettingsSounds = 1 << 4, // was 1
	// BBSectionInfoPushSettingsAlerts = 1 << 2 // wrong
};

#define PUSHER_SUFFICIENT_ALLOW_NOTIFICATIONS_KEY @"AllowNotifications"
#define PUSHER_SUFFICIENT_LOCK_SCREEN_KEY @"LockScreen"
#define PUSHER_SUFFICIENT_NOTIFICATION_CENTER_KEY @"NotificationCenter"
#define PUSHER_SUFFICIENT_BANNERS_KEY @"Banners"
#define PUSHER_SUFFICIENT_BADGES_KEY @"Badges"
// #define PUSHER_SUFFICIENT_SOUNDS_KEY @"Sounds"
#define PUSHER_SUFFICIENT_SHOWS_PREVIEWS_KEY @"ShowsPreviews"

#define NSPPreferenceCustomServicesKey @"CustomServices"
#define NSPPreferenceCustomServiceCustomAppsKey(service) Xstr(@"CustomService_%@_CustomApps", service)
#define NSPPreferenceCustomServiceBLPrefix(service) Xstr(@"CustomServiceBL_%@-", service)
// IF ADDING MORE CUSTOM SERVICE KEY CALCULATORS, REMEMBER TO RENAME THEM UPON CUSTOM SERVICE RENAME IN SERVICE LIST

typedef enum {
	PusherAuthorizationTypeNone,
	PusherAuthorizationTypeHeader,
	PusherAuthorizationTypeCredentials,
	PusherAuthorizationTypeReplaceKey
} PusherAuthorizationType;

// All keys MUST HAVE the prefix equal to the name of the service
#define PUSHER_SERVICE_PUSHOVER @"Pushover"
#define PUSHER_SERVICE_PUSHOVER_APP_ID @"net.superblock.Pushover"
#define PUSHER_SERVICE_PUSHOVER_URL @"https://api.pushover.net/1/messages.json"
#define NSPPreferencePushoverTokenKey @"PushoverToken"
#define NSPPreferencePushoverUserKey @"PushoverUser"
#define NSPPreferencePushoverDevicesKey @"PushoverDevices"
#define NSPPreferencePushoverSoundsKey @"PushoverSounds"
#define NSPPreferencePushoverBLPrefix @"PushoverBL-"
#define NSPPreferencePushoverCustomAppsKey @"PushoverCustomApps"

// All keys MUST HAVE the prefix equal to the name of the service
#define PUSHER_SERVICE_PUSHBULLET @"Pushbullet"
#define PUSHER_SERVICE_PUSHBULLET_APP_ID @"com.pushbullet.client"
#define PUSHER_SERVICE_PUSHBULLET_URL @"https://api.pushbullet.com/v2/pushes"
#define NSPPreferencePushbulletTokenKey @"PushbulletToken"
#define NSPPreferencePushbulletDevicesKey @"PushbulletDevices"
#define NSPPreferencePushbulletBLPrefix @"PushbulletBL-"
#define NSPPreferencePushbulletCustomAppsKey @"PushbulletCustomApps"

// All keys MUST HAVE the prefix equal to the name of the service
#define PUSHER_SERVICE_IFTTT @"IFTTT"
#define PUSHER_SERVICE_IFTTT_URL @"https://maker.ifttt.com/trigger/REPLACE_EVENT_NAME/with/key/REPLACE_KEY"
#define NSPPreferenceIFTTTKeyKey @"IFTTTKey"
#define NSPPreferenceIFTTTEventNameKey @"IFTTTEventName"
#define NSPPreferenceIFTTTDateFormatKey @"IFTTTDateFormat"
#define NSPPreferenceIFTTTBLPrefix @"IFTTTBL-"
#define NSPPreferenceIFTTTCustomAppsKey @"IFTTTCustomApps"
#define NSPPreferenceIFTTTIncludeIconKey @"IFTTTIncludeIcon"
#define NSPPreferenceIFTTTCurateDataKey @"IFTTTCurateData"

#define BUILTIN_PUSHER_SERVICES @[ PUSHER_SERVICE_PUSHOVER, PUSHER_SERVICE_PUSHBULLET, PUSHER_SERVICE_IFTTT ]

#import <Preferences/PSSpecifier.h>
#import <BulletinBoard/BBBulletin.h>
#import <BulletinBoard/BBSectionInfo.h> // imports BBSectionInfoSettings
#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBApplicationController.h>

@interface PSSpecifier (Pusher)
+ (id)emptyGroupSpecifier;
@end

@interface SBLockScreenManager
+ (id)sharedInstance;
@property(readonly) BOOL isUILocked;
@end

@interface BBBulletin (Pusher)
@property (nonatomic, readonly) BOOL showsSubtitle;
@end

@interface BBServer : NSObject
- (BBSectionInfo *)_sectionInfoForSectionID:(id)arg1 effective:(BOOL)arg2;
+ (BBServer *)pusherSharedInstance;
- (void)sendBulletinToPusher:(BBBulletin *)bulletin;
- (void)makePusherRequest:(NSString *)urlString infoDict:(NSDictionary *)infoDict credentials:(NSDictionary *)credentials authType:(PusherAuthorizationType)authType method:(NSString *)method;
- (NSDictionary *)getPusherInfoDictionaryForService:(NSString *)service withDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)getPusherCredentialsForService:(NSString *)service withDictionary:(NSDictionary *)dictionary;
- (void)sendToPusherService:(NSString *)service bulletin:(BBBulletin *)bulletin appID:(NSString *)appID appName:(NSString *)appName title:(NSString *)title message:(NSString *)message isTest:(BOOL)isTest;
- (NSString *)base64IconDataForBundleID:(NSString *)bundleID;
@end

@interface SBApplicationIcon : NSObject
- (UIImage *)generateIconImage:(int)arg1;
@end

@interface SBIconModel : NSObject
- (SBApplicationIcon *)expectedIconForDisplayIdentifier:(id)arg1;
@end

@interface SBIconController : UIViewController
@property (nonatomic, retain) SBIconModel *model;
+ (id)sharedInstance;
@end

@interface SBWiFiManager : NSObject
+ (id)sharedInstance;
- (NSString *)currentNetworkName;
@end

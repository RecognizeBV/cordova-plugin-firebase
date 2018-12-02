#import "AppDelegate+FirebasePlugin.h"
#import "FirebasePlugin.h"
@import Firebase;
#import <objc/runtime.h>
@import Sentry;

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
@import UserNotifications;

// Implement UNUserNotificationCenterDelegate to receive display notification via APNS for devices
// running iOS 10 and above. Implement FIRMessagingDelegate to receive data message via FCM for
// devices running iOS 10 and above.
@interface AppDelegate () <UNUserNotificationCenterDelegate, FIRMessagingDelegate>
@end
#endif

#define kApplicationInBackgroundKey @"applicationInBackground"
#define kDelegateKey @"delegate"

@implementation AppDelegate (FirebasePlugin)

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0

- (void)setDelegate:(id)delegate {
    objc_setAssociatedObject(self, kDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (id)delegate {
    return objc_getAssociatedObject(self, kDelegateKey);
}

#endif

+ (void)initSentry {
    // fetch DSN from config (stored via Info.plist)
    NSString *dsn = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SentryDsn"];

    NSError *error = nil;
    SentryClient *client = [[SentryClient alloc] initWithDsn:dsn didFailWithError:&error];
    SentryClient.sharedClient = client;
    if (nil != error) {
        NSLog(@"Sentry Login Failed: %@", error);
    } else {
        NSLog(@"Sentry Login Succeeded");
    }
}

- (NSString*)getDeviceId {
    UIDevice* device = [UIDevice currentDevice];

    // THIS IS COPIED FROM cordova-plugin-device
    // SAME UUID IS SENT TO API-BACKEND, SO IDENTIFICATION IS POSSIBLE

    // START COPY
    NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
    static NSString* UUID_KEY = @"CDVUUID";

    // Check user defaults first to maintain backwards compaitibility with previous versions
    // which didn't user identifierForVendor
    NSString* app_uuid = [userDefaults stringForKey:UUID_KEY];
    if (app_uuid == nil) {
        if ([device respondsToSelector:@selector(identifierForVendor)]) {
            app_uuid = [[device identifierForVendor] UUIDString];
        } else {
            CFUUIDRef uuid = CFUUIDCreate(NULL);
            app_uuid = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
            CFRelease(uuid);
        }

        [userDefaults setObject:app_uuid forKey:UUID_KEY];
        [userDefaults synchronize];
    }

    return app_uuid;
    // END COPY
}

- (void)logToSentry:(NSString *)data level:(SentrySeverity)level {
    // get current white label application
    NSString* appID = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"];

    // set level
    SentryEvent *event = [[SentryEvent alloc] initWithLevel:level];
    event.message = data;

    // send app ID as environment, distinguishes white label apps + test/staging/production
    event.environment = appID;
    event.tags = @{@"device": [self getDeviceId]};

    // send to sentry
    [SentryClient.sharedClient sendEvent:event withCompletionHandler:^(NSError * _Nullable error) {
        if (error != nil) {
            NSLog(@"Sentry Log Failed: %@", error);
        }
    }];
}

- (void)logToSentry:(NSString *)data {
    [self logToSentry:data level:kSentrySeverityInfo];
}

+ (void)load {
    Method original = class_getInstanceMethod(self, @selector(application:didFinishLaunchingWithOptions:));
    Method swizzled = class_getInstanceMethod(self, @selector(application:swizzledDidFinishLaunchingWithOptions:));
    method_exchangeImplementations(original, swizzled);

    [self initSentry];
}

- (void)setApplicationInBackground:(NSNumber *)applicationInBackground {
    objc_setAssociatedObject(self, kApplicationInBackgroundKey, applicationInBackground, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber *)applicationInBackground {
    return objc_getAssociatedObject(self, kApplicationInBackgroundKey);
}

- (BOOL)application:(UIApplication *)application swizzledDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self logToSentry:@"Device logging stream started."];
    [self application:application swizzledDidFinishLaunchingWithOptions:launchOptions];

    // get GoogleService-Info.plist file path
    NSString *filePath = [[NSBundle mainBundle] pathForResource:@"GoogleService-Info" ofType:@"plist"];

    // if file is successfully found, use it
    if(filePath){
        NSLog(@"GoogleService-Info.plist found, setup: [FIRApp configureWithOptions]");
        // create firebase configure options passing .plist as content
        FIROptions *options = [[FIROptions alloc] initWithContentsOfFile:filePath];

        // configure FIRApp with options
        [FIRApp configureWithOptions:options];
    }

    // no .plist found, try default App
    if (![FIRApp defaultApp] && !filePath) {
        NSLog(@"GoogleService-Info.plist NOT FOUND, setup: [FIRApp defaultApp]");
        [FIRApp configure];
    }

    // [START set_messaging_delegate]
    [FIRMessaging messaging].delegate = self;
    // [END set_messaging_delegate]
#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
    self.delegate = [UNUserNotificationCenter currentNotificationCenter].delegate;
        [UNUserNotificationCenter currentNotificationCenter].delegate = self;
#endif

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tokenRefreshNotification:)
                                                 name:kFIRInstanceIDTokenRefreshNotification object:nil];

    self.applicationInBackground = @(YES);

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self connectToFcm];

    self.applicationInBackground = @(NO);
    }

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self logToSentry:@"Application became inactive. Disconnecting from FCM."];
    [[FIRMessaging messaging] disconnect];
    [self logToSentry:@"Application became inactive. Disconnected from FCM."];
    self.applicationInBackground = @(YES);
    NSLog(@"Disconnected from FCM");
}

- (void)tokenRefreshNotification:(NSNotification *)notification {
    // Note that this callback will be fired everytime a new token is generated, including the first
    // time. So if you need to retrieve the token as soon as it is available this is where that
    // should be done.
    NSString *refreshedToken = [[FIRInstanceID instanceID] token];
    NSLog(@"InstanceID token: %@", refreshedToken);
    [self logToSentry:[NSString stringWithFormat:@"New firebase token received: %@", refreshedToken]];

    // Connect to FCM since connection may have failed when attempted before having a token.
    [self connectToFcm];
    [FirebasePlugin.firebasePlugin sendToken:refreshedToken];
}

- (void)connectToFcm {
    [self logToSentry:@"Connecting to FCM..."];
    [[FIRMessaging messaging] connectWithCompletion:^(NSError * _Nullable error) {
        if (error != nil) {
            [self logToSentry:[NSString stringWithFormat:@"Unable to connect to FCM: %@", error] level:kSentrySeverityError];
            NSLog(@"Unable to connect to FCM. %@", error);
        } else {
            NSLog(@"Connected to FCM.");
            [self logToSentry:@"Connected to FCM."];
            NSString *refreshedToken = [[FIRInstanceID instanceID] token];
            NSLog(@"InstanceID token: %@", refreshedToken);
            [self logToSentry:[NSString stringWithFormat:@"Firebase token received: %@", refreshedToken]];
        }
    }];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [self logToSentry:[NSString stringWithFormat:@"Registered for remote notifications, APNS token received: %@", deviceToken]];
    [FIRMessaging messaging].APNSToken = deviceToken;
    NSLog(@"deviceToken1 = %@", deviceToken);
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
    NSDictionary *mutableUserInfo = [userInfo mutableCopy];

    [mutableUserInfo setValue:self.applicationInBackground forKey:@"tap"];
    [self logToSentry:[NSString stringWithFormat:@"Received notification: %@", mutableUserInfo]];

    // Print full message.
    NSLog(@"%@", mutableUserInfo);

    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {

    NSDictionary *mutableUserInfo = [userInfo mutableCopy];

    [mutableUserInfo setValue:self.applicationInBackground forKey:@"tap"];
    // Print full message.
    NSLog(@"%@", mutableUserInfo);
    [self logToSentry:[NSString stringWithFormat:@"Received notification (with completion handler): %@", mutableUserInfo]];

    completionHandler(UIBackgroundFetchResultNewData);
    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
}

// [START ios_10_data_message]
// Receive data messages on iOS 10+ directly from FCM (bypassing APNs) when the app is in the foreground.
// To enable direct data messages, you can set [Messaging messaging].shouldEstablishDirectChannel to YES.
- (void)messaging:(FIRMessaging *)messaging didReceiveMessage:(FIRMessagingRemoteMessage *)remoteMessage {
    NSLog(@"Received data message: %@", remoteMessage.appData);
    [self logToSentry:[NSString stringWithFormat:@"Received data message: %@", remoteMessage.appData]];

    // This will allow us to handle FCM data-only push messages even if the permission for push
    // notifications is yet missing. This will only work when the app is in the foreground.
    [FirebasePlugin.firebasePlugin sendNotification:remoteMessage.appData];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"Unable to register for remote notifications: %@", error);
    [self logToSentry:[NSString stringWithFormat:@"Unable to register for remote notifications, no APNS token, but error: %@", error] level:kSentrySeverityError];
}

// [END ios_10_data_message]
#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {

    [self.delegate userNotificationCenter:center
              willPresentNotification:notification
                withCompletionHandler:completionHandler];

    if (![notification.request.trigger isKindOfClass:UNPushNotificationTrigger.class])
        return;

    NSDictionary *mutableUserInfo = [notification.request.content.userInfo mutableCopy];

    [mutableUserInfo setValue:self.applicationInBackground forKey:@"tap"];

    // Print full message.
    NSLog(@"%@", mutableUserInfo);
    [self logToSentry:[NSString stringWithFormat:@"Will present notification: %@", mutableUserInfo]];

    completionHandler(UNNotificationPresentationOptionAlert);
    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];
}

- (void) userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler
{
    [self.delegate userNotificationCenter:center
       didReceiveNotificationResponse:response
                withCompletionHandler:completionHandler];

    if (![response.notification.request.trigger isKindOfClass:UNPushNotificationTrigger.class])
        return;

    NSDictionary *mutableUserInfo = [response.notification.request.content.userInfo mutableCopy];

    [mutableUserInfo setValue:@YES forKey:@"tap"];

    // Print full message.
    NSLog(@"Response %@", mutableUserInfo);
    [self logToSentry:[NSString stringWithFormat:@"Did receive notification response: %@", mutableUserInfo]];

    [FirebasePlugin.firebasePlugin sendNotification:mutableUserInfo];

    completionHandler();
}

// Receive data message on iOS 10 devices.
- (void)applicationReceivedRemoteMessage:(FIRMessagingRemoteMessage *)remoteMessage {
    // Print full message
    NSLog(@"%@", [remoteMessage appData]);
    [self logToSentry:[NSString stringWithFormat:@"Received remote data message: %@", [remoteMessage appData]]];
}
#endif

@end

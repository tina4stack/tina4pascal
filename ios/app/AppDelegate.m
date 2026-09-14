#import "AppDelegate.h"
#import "Tina4ViewController.h"

// implemented in libtina4ios.a (tina4ios.pas) — hands the APNs token to the engine
extern void tina4_push_token(const char *platform, const char *token);

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [Tina4ViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

// APNs handed us a device token — hex-encode it and pass it to the engine, which
// forwards it to whatever the app wired (typically a POST to the Tina4 backend).
- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    const unsigned char *b = deviceToken.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:deviceToken.length * 2];
    for (NSUInteger i = 0; i < deviceToken.length; i++) [hex appendFormat:@"%02x", b[i]];
    tina4_push_token("ios", hex.UTF8String);
}

- (void)application:(UIApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    NSLog(@"Tina4: APNs registration failed - %@", error.localizedDescription);
}

@end

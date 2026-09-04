#import "AppDelegate.h"
#import "Tina4ViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [Tina4ViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

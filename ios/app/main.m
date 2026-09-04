#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "tina4.h"

// The whole UI is drawn by the Pascal engine (libtina4ios.a). PASCALMAIN sets
// up the FPC runtime + units; call it once before UIKit starts.
int main(int argc, char *argv[]) {
    PASCALMAIN();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([AppDelegate class]));
    }
}

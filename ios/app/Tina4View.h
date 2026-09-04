#import <UIKit/UIKit.h>

// A single custom view whose every pixel is drawn by the native Tina4 engine.
// The owning view controller sets `host` so the view can present the file /
// camera pickers, and feeds captured results back via setPickedFile/Photo.
@interface Tina4View : UIView <UIKeyInput>
@property (weak, nonatomic) UIViewController *host;
- (void)loadHTML:(NSString *)html;
- (void)setPickedFile:(NSString *)name;
- (void)setPickedPhoto:(NSString *)path;
@end

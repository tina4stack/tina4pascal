#import "Tina4View.h"
#import "tina4.h"
#import <MobileCoreServices/MobileCoreServices.h>

@interface Tina4View () <UIImagePickerControllerDelegate,
                         UINavigationControllerDelegate,
                         UIDocumentPickerDelegate>
@property (strong, nonatomic) CADisplayLink *fling;
@property (strong, nonatomic) NSTimer *caret;
@end

@implementation Tina4View

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentMode = UIViewContentModeRedraw;   // redraw on resize/rotate
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (void)loadHTML:(NSString *)html {
    tina4_set_html(html.UTF8String);
    [self setNeedsDisplay];
}

// ---- drawing -----------------------------------------------------------

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // A drawRect context is top-left / y-down and in POINTS, matching the
    // engine's CSS-px space — so hand it points and density 1.
    tina4_frame(ctx, (int)self.bounds.size.width,
                     (int)self.bounds.size.height, 1.0f);
    // autofocus: the engine parses on the first frame, so poll here
    if (tina4_wants_keyboard()) [self showKeyboard];
}

// ---- touch → engine ----------------------------------------------------

- (void)send:(int)action touches:(NSSet<UITouch *> *)touches {
    CGPoint p = [[touches anyObject] locationInView:self];
    int r = tina4_touch(action, p.x, p.y);
    if (r == TINA_SHOW_KBD)      [self showKeyboard];
    else if (r == TINA_FLING)    [self startFling];
    else if (r == TINA_PICK_FILE)[self pickFile];
    else if (r == TINA_CAPTURE)  [self capturePhoto];
    // deterministic keyboard: up only while a text field is focused
    if (r != TINA_SHOW_KBD && tina4_focus_kind() == 0) [self hideKeyboard];
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self stopFling]; [self send:0 touches:t]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:2 touches:t]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:1 touches:t]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:1 touches:t]; }

// ---- momentum + caret --------------------------------------------------

- (void)startFling {
    [self stopFling];
    self.fling = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.fling addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)stopFling { [self.fling invalidate]; self.fling = nil; }
- (void)tick { if (tina4_tick()) [self setNeedsDisplay]; else [self stopFling]; }

- (void)startCaret {
    [self stopCaret];
    self.caret = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
        selector:@selector(blink) userInfo:nil repeats:YES];
}
- (void)stopCaret { [self.caret invalidate]; self.caret = nil; }
- (void)blink { if (tina4_blink_caret()) [self setNeedsDisplay]; else [self stopCaret]; }

// ---- keyboard ----------------------------------------------------------

- (BOOL)canBecomeFirstResponder { return YES; }
- (void)showKeyboard { if (![self isFirstResponder]) [self becomeFirstResponder]; [self startCaret]; }
- (void)hideKeyboard { if ([self isFirstResponder]) [self resignFirstResponder]; [self stopCaret]; }

- (BOOL)resignFirstResponder { tina4_blur(); [self stopCaret]; [self setNeedsDisplay]; return [super resignFirstResponder]; }

// UIKeyInput: feed characters to the engine
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        if (tina4_focus_kind() == 2) {
            tina4_key(10);                       // textarea: newline
        } else {                                 // text field: the Return key = Next
            if (tina4_focus_next() == 0) [self hideKeyboard];
            else [self reloadInputViews];        // re-read returnKeyType for the new field
        }
    } else {
        NSUInteger n = text.length, i = 0;
        while (i < n) {
            unichar c = [text characterAtIndex:i++];
            tina4_key((int)c);
        }
    }
    [self setNeedsDisplay];
}
- (void)deleteBackward { tina4_key(8); [self setNeedsDisplay]; }

// textarea wants a return key that inserts a newline; a text field advances.
- (UIReturnKeyType)returnKeyType { return tina4_focus_kind() == 2 ? UIReturnKeyDefault : UIReturnKeyNext; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }

// ---- file + camera pickers --------------------------------------------

- (void)pickFile {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[(NSString *)kUTTypeItem] inMode:UIDocumentPickerModeImport];
    p.delegate = self;
    [self.host presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count) [self setPickedFile:urls.firstObject.lastPathComponent];
}

- (void)capturePhoto {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) return;
    UIImagePickerController *p = [UIImagePickerController new];
    p.sourceType = UIImagePickerControllerSourceTypeCamera;
    p.delegate = self;
    [self.host presentViewController:p animated:YES completion:nil];
}
- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!img) return;
    // The camera tags portrait shots with an EXIF orientation; our Core Graphics
    // canvas draws raw pixels and ignores it, so bake the rotation into the
    // pixels (draw upright) before saving.
    if (img.imageOrientation != UIImageOrientationUp) {
        UIGraphicsBeginImageContextWithOptions(img.size, NO, img.scale);
        [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
        UIImage *fixed = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (fixed) img = fixed;
    }
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"IMG_%.0f.jpg", [NSDate date].timeIntervalSince1970]];
    [UIImageJPEGRepresentation(img, 0.9) writeToFile:path atomically:YES];
    [self setPickedPhoto:path];
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)setPickedFile:(NSString *)name { tina4_set_file(name.UTF8String); [self setNeedsDisplay]; }
- (void)setPickedPhoto:(NSString *)path { tina4_set_photo(path.UTF8String); [self setNeedsDisplay]; }

@end

#import "Tina4View.h"
#import "tina4.h"
#import <MobileCoreServices/MobileCoreServices.h>

@interface Tina4View () <UIImagePickerControllerDelegate,
                         UINavigationControllerDelegate,
                         UIDocumentPickerDelegate>
@property (strong, nonatomic) CADisplayLink *fling;
@property (strong, nonatomic) NSTimer *caret;
@property (strong, nonatomic) CADisplayLink *pump;   // redraws while HTTP is in flight
@end

@implementation Tina4View

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentMode = UIViewContentModeRedraw;   // redraw on resize/rotate
        self.multipleTouchEnabled = NO;
        // the engine paints the safe area; the status-bar / home-indicator strips
        // outside it show this colour — match the page background (--paper)
        self.backgroundColor = [UIColor colorWithRed:0.984 green:0.980 blue:0.969 alpha:1.0];
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
    // Keep content out from under the status bar / notch / home indicator:
    // shift the engine's origin into the safe area and hand it the inset size.
    // (Touches are un-inset by the same amount in -send:touches:.)
    UIEdgeInsets s = self.safeAreaInsets;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, s.left, s.top);
    // A drawRect context is top-left / y-down and in POINTS, matching the
    // engine's CSS-px space — so hand it points and density 1.
    tina4_frame(ctx, (int)(self.bounds.size.width  - s.left - s.right),
                     (int)(self.bounds.size.height - s.top  - s.bottom), 1.0f);
    CGContextRestoreGState(ctx);
    // autofocus: the engine parses on the first frame, so poll here
    if (tina4_wants_keyboard()) [self showKeyboard];
}

// ---- touch → engine ----------------------------------------------------

- (void)send:(int)action touches:(NSSet<UITouch *> *)touches {
    CGPoint p = [[touches anyObject] locationInView:self];
    UIEdgeInsets s = self.safeAreaInsets;   // match the drawRect inset
    int r = tina4_touch(action, p.x - s.left, p.y - s.top);
    if (r == TINA_SHOW_KBD)      [self showKeyboard];
    else if (r == TINA_FLING)    [self startFling];
    else if (r == TINA_PICK_FILE)[self pickFile];
    else if (r == TINA_CAPTURE)  [self capturePhoto];
    // deterministic keyboard: up only while a text field is focused
    if (r != TINA_SHOW_KBD && tina4_focus_kind() == 0) [self hideKeyboard];
    [self setNeedsDisplay];
    // On touch-DOWN paint synchronously so the :active press colour actually
    // shows: a quick tap's down+up would otherwise coalesce into one frame and
    // the pressed state would never render.
    if (action == 0) [self.layer displayIfNeeded];
    // a tap may have kicked off an HTTP request (onclick → Http:Get); keep
    // redrawing until the async reply is pumped in, so it isn't "stuck" on
    // Loading until the next touch.
    if (tina4_http_pending() > 0) [self startPump];
}

// ---- HTTP pump: light redraw loop while a request is in flight ---------
- (void)startPump {
    if (self.pump) return;
    self.pump = [CADisplayLink displayLinkWithTarget:self selector:@selector(pumpTick)];
    if (@available(iOS 15.0, *)) self.pump.preferredFrameRateRange = CAFrameRateRangeMake(8, 15, 12);
    else self.pump.preferredFramesPerSecond = 12;
    [self.pump addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)stopPump { [self.pump invalidate]; self.pump = nil; }
- (void)pumpTick {
    [self setNeedsDisplay];               // drawRect drains HttpPump + repaints
    if (tina4_http_pending() == 0) [self stopPump];
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

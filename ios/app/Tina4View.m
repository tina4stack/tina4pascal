#import "Tina4View.h"
#import "tina4.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

@interface Tina4View () <UIImagePickerControllerDelegate,
                         UINavigationControllerDelegate,
                         UIDocumentPickerDelegate>
@property (strong, nonatomic) CADisplayLink *fling;
@property (strong, nonatomic) NSTimer *caret;
@property (strong, nonatomic) CADisplayLink *pump;   // redraws while HTTP is in flight
// native <video> overlays, keyed by source URL. Each is a full AVPlayerViewController
// (native play/pause/scrub/fullscreen controls), positioned over the engine's black
// poster box each frame (see -syncVideos:).
@property (strong, nonatomic) NSMutableDictionary<NSString *, AVPlayerViewController *> *videoControllers;
@property (strong, nonatomic) NSMutableDictionary<NSString *, id> *videoLoopObservers;
@property (strong, nonatomic) NSMutableDictionary<NSString *, NSNumber *> *videoFlags;   // bit0 controls·1 autoplay·2 loop·3 muted
@end

@implementation Tina4View

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentMode = UIViewContentModeRedraw;   // redraw on resize/rotate
        self.multipleTouchEnabled = NO;
        self.clipsToBounds = YES;                      // keep video views inside the view
        _videoControllers = [NSMutableDictionary dictionary];
        _videoLoopObservers = [NSMutableDictionary dictionary];
        _videoFlags = [NSMutableDictionary dictionary];
        // a playback audio session so <video> actually starts (even muted)
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        // the engine paints the safe area; the status-bar / home-indicator strips
        // outside it show this colour — match the page background (--paper)
        self.backgroundColor = [UIColor colorWithRed:0.984 green:0.980 blue:0.969 alpha:1.0];
    }
    return self;
}

- (void)loadHTML:(NSString *)html {
    // resolve a relative <img src="assets/…"> against the app bundle (where the
    // project's assets are bundled) — the iOS analogue of Android's asset base.
    tina4_set_asset_base([[NSBundle mainBundle] resourcePath].UTF8String);
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
    int w = (int)(self.bounds.size.width  - s.left - s.right);
    int h = (int)(self.bounds.size.height - s.top  - s.bottom);
    // Partial redraw: if iOS handed us a sub-rect (an animation-only frame
    // invalidated just the animated region) — not the whole view — repaint only
    // that region; the layer retains the rest. A full invalidate (input, scroll,
    // relayout) coalesces to ~the full bounds → full repaint.
    BOOL full = (rect.size.width  >= self.bounds.size.width  - 1.0f) &&
                (rect.size.height >= self.bounds.size.height - 1.0f);
    if (!full && tina4_anim_region(NULL, NULL, NULL, NULL))
        tina4_frame_region(ctx, w, h, 1.0f);
    else
        tina4_frame(ctx, w, h, 1.0f);
    CGContextRestoreGState(ctx);
    // overlay/position native <video> players over their poster boxes. Do this
    // OFF the drawRect pass — mutating the layer tree (addSublayer) inside
    // drawRect is unreliable — so hop to the next main-loop turn.
    dispatch_async(dispatch_get_main_queue(), ^{ [self syncVideos:s]; });
    // keep animating on-screen time-driven content (<lottie>) without needing a
    // fling — the display link paces itself and -tick repaints only the animated
    // region (setNeedsDisplayInRect).
    if (tina4_anim_active() && !self.fling) [self startFling];
    // autofocus: the engine parses on the first frame, so poll here
    if (tina4_wants_keyboard()) [self showKeyboard];
    // a frame may have kicked off remote <img> downloads — keep repainting until
    // they arrive (no touch needed on page load).
    if (tina4_ios_images_pending() > 0) [self startPump];
}

// ---- native <video> overlays ------------------------------------------
// The engine lays out each <video> as a sized black poster box and reports its
// screen rect + source. We keep one AVPlayerLayer per source, position it over
// the poster (offset into the safe area like the engine's content), and reuse
// it across frames so scrolling just repositions — no reload.

// AVPlayerItem became ready (or failed) — start playback for its controller.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"status"] || ![object isKindOfClass:[AVPlayerItem class]]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        for (NSString *src in self.videoControllers) {
            AVPlayerViewController *vc = self.videoControllers[src];
            if (vc.player.currentItem == item) {
                // autoplay only when the <video> has the `autoplay` attribute
                if ((self.videoFlags[src].intValue & 2) != 0) [vc.player play];
                break;
            }
        }
    } else if (item.status == AVPlayerItemStatusFailed) {
        NSLog(@"[tina4] video item failed: %@", item.error);
    }
}

- (void)syncVideos:(UIEdgeInsets)s {
    int n = tina4_embed_count();
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    for (int i = 0; i < n; i++) {
        char buf[2048];
        int len = tina4_embed_src(i, buf, (int)sizeof(buf));
        if (len <= 0) continue;
        NSString *src = [NSString stringWithUTF8String:buf];
        float x = 0, y = 0, w = 0, h = 0;
        tina4_embed_rect(i, &x, &y, &w, &h);
        if (w <= 0 || h <= 0) continue;
        [live addObject:src];

        AVPlayerViewController *vc = self.videoControllers[src];
        if (!vc) {
            NSURL *url = [NSURL URLWithString:src];
            if (!url) continue;
            int flags = tina4_embed_flags(i);   // 1 controls·2 autoplay·4 loop·8 muted
            BOOL wantControls = (flags & 1) != 0;
            BOOL wantLoop     = (flags & 4) != 0;
            BOOL wantMuted    = (flags & 8) != 0;
            self.videoFlags[src] = @(flags);
            AVPlayer *player = [AVPlayer playerWithURL:url];
            player.muted = wantMuted;           // honor the `muted` attribute
            player.allowsExternalPlayback = NO; // keep video on-device (don't AirPlay it away)
            vc = [[AVPlayerViewController alloc] init];
            vc.player = player;
            vc.showsPlaybackControls = wantControls;   // honor the `controls` attribute
            vc.videoGravity = AVLayerVideoGravityResizeAspect;
            vc.view.backgroundColor = [UIColor blackColor];
            if (self.host) [self.host addChildViewController:vc];
            [self addSubview:vc.view];
            if (self.host) [vc didMoveToParentViewController:self.host];
            self.videoControllers[src] = vc;
            // autoplay happens on the status→ready KVO (below) only if `autoplay`
            [player.currentItem addObserver:self forKeyPath:@"status"
                                    options:NSKeyValueObservingOptionNew context:NULL];
            // loop: rewind on end, only if the `loop` attribute is present
            if (wantLoop) {
                __weak AVPlayer *wplayer = player;
                id obs = [[NSNotificationCenter defaultCenter]
                    addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                object:player.currentItem
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                                [wplayer seekToTime:kCMTimeZero];
                                [wplayer play];
                            }];
                self.videoLoopObservers[src] = obs;
            }
        }
        // reposition to track scroll (no implicit animation)
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        vc.view.frame = CGRectMake(x + s.left, y + s.top, w, h);
        [CATransaction commit];
    }
    // tear down controllers whose <video> is no longer laid out
    NSMutableArray<NSString *> *dead = [NSMutableArray array];
    for (NSString *src in self.videoControllers)
        if (![live containsObject:src]) [dead addObject:src];
    for (NSString *src in dead) {
        AVPlayerViewController *vc = self.videoControllers[src];
        [vc.player pause];
        @try { [vc.player.currentItem removeObserver:self forKeyPath:@"status"]; } @catch (__unused id e) {}
        [vc willMoveToParentViewController:nil];
        [vc.view removeFromSuperview];
        [vc removeFromParentViewController];
        id obs = self.videoLoopObservers[src];
        if (obs) [[NSNotificationCenter defaultCenter] removeObserver:obs];
        [self.videoLoopObservers removeObjectForKey:src];
        [self.videoControllers removeObjectForKey:src];
        [self.videoFlags removeObjectForKey:src];
    }
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
    if (tina4_http_pending() == 0 && tina4_ios_images_pending() == 0) [self stopPump];
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
// The display link that keeps both fling momentum AND <lottie> animation going.
// tina4_tick() returns 0 idle · 1 animation-only · 2 fling (content moving). For an
// animation-only frame, invalidate ONLY the animated region so drawRect: repaints
// just that rect and the layer retains the rest (partial redraw = the iOS win).
- (void)tick {
    int t = tina4_tick();
    if (t == 0) { [self stopFling]; return; }
    float r[4];
    if (t == 1 && tina4_anim_region(&r[0], &r[1], &r[2], &r[3])) {
        UIEdgeInsets s = self.safeAreaInsets;         // region is in engine points; un-inset
        // inflate to match TinaFrameRegion's AA/shadow padding
        [self setNeedsDisplayInRect:CGRectInset(CGRectMake(r[0] + s.left, r[1] + s.top, r[2], r[3]), -4, -4)];
    } else {
        [self setNeedsDisplay];                       // fling / no confined region → full
    }
}

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

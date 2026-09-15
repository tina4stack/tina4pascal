// Remote-image loader for the native Tina4 iOS-Simulator canvas — a port of the
// device loader (ios/app/ImageLoader.m). The shell calls tina4_ios_fetch_image
// for an http(s) <img src>, we download it over NSURLSession (Apple's native
// TLS, no OpenSSL) to the on-disk cache path the Pascal side computed, then post
// Tina4ImageReady so the SwiftUI view re-renders and the shell decodes the
// now-present file via Core Graphics / ImageIO. Bundled/local images never reach
// here (the shell reads them straight off disk).
#import <Foundation/Foundation.h>

// exported by libtina4iossim.a — forces the engine to relayout so the next
// frame re-runs LoadImage and decodes the now-cached file.
extern void tina4_image_ready(void);

NSString * const Tina4ImageReadyNote = @"Tina4ImageReady";

static NSMutableSet<NSString *> *gInflight;   // URLs currently downloading
static NSLock *gLock;

static void ensure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gInflight = [NSMutableSet set]; gLock = [NSLock new]; });
}

// How many downloads are still in flight — the view can keep repainting while
// images arrive.
int tina4_ios_images_pending(void) {
    ensure();
    [gLock lock]; NSUInteger n = gInflight.count; [gLock unlock];
    return (int)n;
}

void tina4_ios_fetch_image(const char *cUrl, const char *cPath) {
    ensure();
    NSString *url  = cUrl  ? [NSString stringWithUTF8String:cUrl]  : nil;
    NSString *path = cPath ? [NSString stringWithUTF8String:cPath] : nil;
    if (url.length == 0 || path.length == 0) return;

    [gLock lock];
    if ([gInflight containsObject:url]) { [gLock unlock]; return; }   // already downloading
    [gInflight addObject:url];
    [gLock unlock];

    NSURL *u = [NSURL URLWithString:url];
    if (!u) { [gLock lock]; [gInflight removeObject:url]; [gLock unlock]; return; }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:u
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            if (data && !error && data.length > 0)
                [data writeToFile:path atomically:YES];
            // back on the main thread: the FPC engine is single-threaded
            dispatch_async(dispatch_get_main_queue(), ^{
                [gLock lock]; [gInflight removeObject:url]; [gLock unlock];
                tina4_image_ready();   // engine: relayout (re-run LoadImage next frame)
                // and ask the view to draw that frame; the shell decodes the cached file
                [[NSNotificationCenter defaultCenter] postNotificationName:Tina4ImageReadyNote object:nil];
            });
        }];
    [task resume];
}

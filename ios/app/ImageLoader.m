// Async remote-image loader for the Tina4 iOS canvas. Downloads an <img src>
// over NSURLSession (Apple's native TLS — no OpenSSL) to the on-disk cache the
// Pascal side computed, then calls tina4_image_ready so the engine relayouts and
// TIOSCanvas.LoadImage decodes the now-present file. Idempotent per URL, and the
// in-flight count lets the view keep repainting until images land.
#import <Foundation/Foundation.h>

// exported by libtina4ios.a (Tina4ios.tina4_image_ready)
extern void tina4_image_ready(void);

static NSMutableSet<NSString *> *gInflight;   // URLs currently downloading
static NSLock *gLock;

static void ensure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gInflight = [NSMutableSet set]; gLock = [NSLock new]; });
}

// How many image downloads are still in flight — the view polls this to keep its
// repaint loop alive while images are arriving.
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
                tina4_image_ready();   // relayout → decode the cached file
            });
        }];
    [task resume];
}

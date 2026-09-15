// The native shell (Tina4ShellIOS) calls tina4_ios_fetch_image to load <img>
// sources asynchronously; the full device host implements it in ImageLoader.m
// (ImageIO + a tina4_image_ready callback). This minimal Simulator host renders
// a clock with no images, so we satisfy the symbol with a no-op — add the real
// loader here when a page needs <img>.
#import <Foundation/Foundation.h>

void tina4_ios_fetch_image(const char *cUrl, const char *cPath) {
    (void)cUrl; (void)cPath;
}

// Native iOS HTTP for the Tina4 HTTP backend. tina4_ios_http_send (called from
// Pascal) runs an NSURLSession data task — Apple's native TLS, no OpenSSL — and
// on completion calls the Pascal export tina4_http_result, which queues the
// response for the engine's HttpPump on the main thread.
#import <Foundation/Foundation.h>

// exported by libtina4ios.a (Tina4HttpIOS.tina4_http_result)
extern void tina4_http_result(int id, int status, const char *body, const char *error);

void tina4_ios_http_send(int reqId, const char *cMethod, const char *cUrl,
                         const char *cBody, const char *cCtype, const char *cHeaders) {
    NSString *method = cMethod ? [NSString stringWithUTF8String:cMethod] : @"GET";
    NSString *urlStr = cUrl ? [NSString stringWithUTF8String:cUrl] : @"";
    NSString *body   = cBody ? [NSString stringWithUTF8String:cBody] : @"";
    NSString *ctype  = cCtype ? [NSString stringWithUTF8String:cCtype] : @"";
    NSString *headers = cHeaders ? [NSString stringWithUTF8String:cHeaders] : @"";

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { tina4_http_result(reqId, 0, "", "bad url"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method.length ? method : @"GET";
    req.timeoutInterval = 20;
    [req setValue:@"Tina4Pascal" forHTTPHeaderField:@"User-Agent"];
    // extra headers: one "Name: Value" per line (auth etc.)
    if (headers.length) {
        for (NSString *line in [headers componentsSeparatedByString:@"\n"]) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *name = [[line substringToIndex:colon.location]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *val  = [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (name.length) [req setValue:val forHTTPHeaderField:name];
        }
    }
    if (body.length) {
        req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
        if (ctype.length) [req setValue:ctype forHTTPHeaderField:@"Content-Type"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            // This block runs on a background queue. The Pascal engine (and its
            // heap) is single-threaded, so NOTHING Pascal may be touched here —
            // marshal the result onto the main thread first. Without this, spamming
            // requests fires many completions at once and corrupts the FPC heap.
            int status = 0;
            NSString *sResp = @"", *sErr = @"";
            if (error) {
                sErr = error.localizedDescription ?: @"";
            } else {
                if ([resp isKindOfClass:[NSHTTPURLResponse class]])
                    status = (int)((NSHTTPURLResponse *)resp).statusCode;
                if (data) {
                    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (s) sResp = s;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                tina4_http_result(reqId, status, sResp.UTF8String, sErr.UTF8String);
            });
        }];
    [task resume];
}

// Native iOS HTTP for the Tina4 HTTP backend. tina4_ios_http_send (called from
// Pascal) runs an NSURLSession data task — Apple's native TLS, no OpenSSL — and
// on completion calls the Pascal export tina4_http_result, which queues the
// response for the engine's HttpPump on the main thread.
#import <Foundation/Foundation.h>

// exported by libtina4ios.a (Tina4HttpIOS.tina4_http_result)
extern void tina4_http_result(int id, int status, const char *body, const char *error);

void tina4_ios_http_send(int reqId, const char *cMethod, const char *cUrl,
                         const char *cBody, const char *cCtype) {
    NSString *method = cMethod ? [NSString stringWithUTF8String:cMethod] : @"GET";
    NSString *urlStr = cUrl ? [NSString stringWithUTF8String:cUrl] : @"";
    NSString *body   = cBody ? [NSString stringWithUTF8String:cBody] : @"";
    NSString *ctype  = cCtype ? [NSString stringWithUTF8String:cCtype] : @"";

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { tina4_http_result(reqId, 0, "", "bad url"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method.length ? method : @"GET";
    req.timeoutInterval = 20;
    [req setValue:@"Tina4Pascal" forHTTPHeaderField:@"User-Agent"];
    if (body.length) {
        req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
        if (ctype.length) [req setValue:ctype forHTTPHeaderField:@"Content-Type"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            int status = 0;
            const char *cResp = "";
            const char *cErr = "";
            NSString *sResp = nil, *sErr = nil;
            if (error) {
                sErr = error.localizedDescription;
                cErr = sErr.UTF8String;
            } else {
                if ([resp isKindOfClass:[NSHTTPURLResponse class]])
                    status = (int)((NSHTTPURLResponse *)resp).statusCode;
                sResp = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                cResp = (sResp ?: @"").UTF8String;
            }
            tina4_http_result(reqId, status, cResp, cErr);
        }];
    [task resume];
}

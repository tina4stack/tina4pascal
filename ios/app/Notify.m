// Local notifications for the Tina4 iOS shell. The Pascal side (Tina4ShellIOS →
// Tina4SetNotifyHandler) calls tina4_ios_notify; notify.show('Title','Body') in
// HTML lands here. Local only (no push entitlement needed); these auto-forward to
// a paired Apple Watch when the app isn't foreground. Remote (APNs) is Phase 2.
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

// Ask the user once (call at launch). Safe to call repeatedly.
void tina4_ios_notify_authorize(void) {
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert |
                                        UNAuthorizationOptionSound |
                                        UNAuthorizationOptionBadge)
                     completionHandler:^(BOOL granted, NSError *err) { /* no-op */ }];
}

// Post a local notification now. `tag` (optional) lets a later notification with
// the same identifier replace an earlier one.
void tina4_ios_notify(const char *title, const char *body, const char *tag) {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title ? [NSString stringWithUTF8String:title] : @"";
    content.body  = body  ? [NSString stringWithUTF8String:body]  : @"";
    content.sound = [UNNotificationSound defaultSound];

    NSString *ident = (tag && tag[0]) ? [NSString stringWithUTF8String:tag]
                                      : [[NSUUID UUID] UUIDString];
    // fire almost immediately (a tiny delay is required for a time-interval trigger)
    UNTimeIntervalNotificationTrigger *trig =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest *req =
        [UNNotificationRequest requestWithIdentifier:ident content:content trigger:trig];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:req withCompletionHandler:nil];
}

#import "Tweak.h"

static inline BOOL YSR_IsLandscape(UIInterfaceOrientation o)
{
    return o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight;
}

static UIInterfaceOrientationMask YSR_NonUpsideDownMask(void)
{
    return (UIInterfaceOrientationMaskAllButUpsideDown);
}

static void YSR_ForceOrientation(UIInterfaceOrientation orientation)
{
    if ([[UIDevice currentDevice] respondsToSelector:@selector(setValue:forKey:)])
    {
        [UIDevice.currentDevice setValue:@(orientation) forKey:@"orientation"];
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

static UIInterfaceOrientation YSR_CurrentInterfaceOrientation(void)
{
    NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
    for (UIScene *s in scenes)
    {
        if (![s isKindOfClass:[UIWindowScene class]])
            continue;
        UIWindowScene *ws = (UIWindowScene *) s;
        if (ws.activationState == UISceneActivationStateForegroundActive)
        {
            return ws.interfaceOrientation;
        }
    }
    return UIInterfaceOrientationUnknown;
}

typedef NS_ENUM(NSInteger, YSRMode) {
    YSRModeUnknown = 0,
    YSRModeInline,
    YSRModeFullscreen
};

static volatile YSRMode gMode            = YSRModeUnknown;
static volatile BOOL    gAllowUpsideDown = YES;

static BOOL YSR_ShouldAllow(UIInterfaceOrientation toOrientation)
{
    if (toOrientation == UIInterfaceOrientationPortraitUpsideDown)
    {
        return gAllowUpsideDown;
    }
    return YES;
}

static CFAbsoluteTime gLastRotationAt = 0;
static BOOL           YSR_DebounceRotation(NSTimeInterval minInterval)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastRotationAt < minInterval)
        return YES;
    gLastRotationAt = now;
    return NO;
}

%hook UIViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    UIInterfaceOrientationMask original = %orig;

    if (gMode == YSRModeFullscreen)
    {
        UIInterfaceOrientationMask desired = UIInterfaceOrientationMaskAllButUpsideDown;
        if ((original & (UIInterfaceOrientationMaskLandscape)) == 0)
        {
            return desired;
        }
        return (original & ~UIInterfaceOrientationMaskPortraitUpsideDown);
    }

    if (original == 0)
    {
        return YSR_NonUpsideDownMask();
    }
    return (original & ~UIInterfaceOrientationMaskPortraitUpsideDown);
}

- (BOOL)shouldAutorotate
{
    BOOL orig = %orig;
    return orig;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
    UIInterfaceOrientation pref = %orig;
    if (pref == UIInterfaceOrientationPortraitUpsideDown)
        return UIInterfaceOrientationPortrait;
    return pref;
}

%end

%hook UINavigationController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return self.topViewController ? [self.topViewController supportedInterfaceOrientations]
                                  : %orig;
}
- (BOOL)shouldAutorotate
{
    return self.topViewController ? [self.topViewController shouldAutorotate] : %orig;
}
%end

%hook UIWindow
- (BOOL)_shouldAutorotateToOrientation:(long long)orientation
{
    if (!YSR_ShouldAllow((UIInterfaceOrientation) orientation))
        return NO;
    return %orig;
}
%end

%hook UIApplication
- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    UIInterfaceOrientationMask mask = %orig;
    if (mask == 0)
        mask = UIInterfaceOrientationMaskAll;
    return (mask & ~UIInterfaceOrientationMaskPortraitUpsideDown);
}
%end

%hook YTWatchController

- (void)showFullScreen
{
    gMode            = YSRModeFullscreen;
    gAllowUpsideDown = NO;
    %orig;
    if (!YSR_DebounceRotation(0.2))
    {
        UIInterfaceOrientation current = YSR_CurrentInterfaceOrientation();
        if (!YSR_IsLandscape(current))
        {
            YSR_ForceOrientation(UIInterfaceOrientationLandscapeRight);
        }
        else
        {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    }
}

- (void)showSmallScreen
{
    gMode            = YSRModeInline;
    gAllowUpsideDown = NO;
    %orig;
    if (!YSR_DebounceRotation(0.2))
    {
        UIInterfaceOrientation current = YSR_CurrentInterfaceOrientation();
        if (current == UIInterfaceOrientationPortraitUpsideDown)
        {
            YSR_ForceOrientation(UIInterfaceOrientationPortrait);
        }
        else
        {
            [UIViewController attemptRotationToDeviceOrientation];
        }
    }
}

%end

%ctor
{
    gMode            = YSRModeUnknown;
    gAllowUpsideDown = YES;
    gLastRotationAt  = 0;

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
                    if (YSR_DebounceRotation(0.12))
                        return;
                    UIDeviceOrientation    dev = UIDevice.currentDevice.orientation;
                    UIInterfaceOrientation target;
                    switch (dev)
                    {
                        case UIDeviceOrientationLandscapeLeft:
                            target = UIInterfaceOrientationLandscapeRight;
                            break;
                        case UIDeviceOrientationLandscapeRight:
                            target = UIInterfaceOrientationLandscapeLeft;
                            break;
                        case UIDeviceOrientationPortraitUpsideDown:
                            target = UIInterfaceOrientationPortraitUpsideDown;
                            break;
                        case UIDeviceOrientationPortrait:
                        default:
                            target = UIInterfaceOrientationPortrait;
                            break;
                    }
                    if (!YSR_ShouldAllow(target))
                    {
                        target = UIInterfaceOrientationPortrait;
                    }

                    UIInterfaceOrientation cur = YSR_CurrentInterfaceOrientation();
                    if (cur != target)
                    {
                        YSR_ForceOrientation(target);
                    }
                }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) { gLastRotationAt = 0; }];
}

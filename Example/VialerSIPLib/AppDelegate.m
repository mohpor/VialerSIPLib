//
//  AppDelegate.m
//  Copyright © 2015 Devhouse Spindle. All rights reserved.
//

#import "AppDelegate.h"
#import "HDLumberjackLogFormatter.h"
#import "SipUser.h"
#import "Keys.h"
#import <VialerSIPLib-iOS/VialerSIPLib.h>

static const DDLogLevel ddLogLevel = DDLogLevelVerbose;
NSString * const AppDelegateIncominCallNotification = @"AppDelegateIncominCallNotification";

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self setupCocoaLumberjackLogging];

    VSLEndpointConfiguration *endpointConfiguration = [[VSLEndpointConfiguration alloc] init];
    VSLTransportConfiguration *updTransportConfiguration = [VSLTransportConfiguration configurationWithTransportType:VSLTransportTypeUDP];

    endpointConfiguration.transportConfigurations = @[updTransportConfiguration];

    NSError *error;
    BOOL success = [[VialerSIPLib sharedInstance] configureLibraryWithEndPointConfiguration:endpointConfiguration error:&error];
    if (!success || error) {
        DDLogError(@"Failed to startup VialerSIPLib: %@", error);
    } else {
        SipUser *testUser = [[SipUser alloc] init];
        testUser.sipUsername = KeysUsername;
        testUser.sipPassword = KeysPassword;
        testUser.sipDomain = KeysDomain;
        testUser.sipProxy = KeysProxy;
        testUser.sipRegisterOnAdd = NO;

        NSError *error;
        [[VialerSIPLib sharedInstance] createAccountWithSipUser:testUser error:&error];
        if (error) {
            DDLogError(@"Failed to create Account: %@", error);
        }
        [self setupCallbackForVialerSIPLib];
    }
    return YES;
}

- (void)setupCocoaLumberjackLogging {
    //Add the Terminal and TTY(XCode console) loggers to CocoaLumberjack (simulate the default NSLog behaviour)
    HDLumberjackLogFormatter* logFormat = [[HDLumberjackLogFormatter alloc] init];

    DDASLLogger *aslLogger = [DDASLLogger sharedInstance];
    [aslLogger setLogFormatter: logFormat];
    DDTTYLogger *ttyLogger = [DDTTYLogger sharedInstance];
    [ttyLogger setLogFormatter:logFormat];
    [ttyLogger setColorsEnabled:YES];

    //Give INFO a color
    UIColor *pink = [UIColor colorWithRed:(255/255.0) green:(58/255.0) blue:(159/255.0) alpha:1.0];
    [[DDTTYLogger sharedInstance] setForegroundColor:pink backgroundColor:nil forFlag:DDLogFlagInfo];

    [DDLog addLogger:aslLogger];
    [DDLog addLogger:ttyLogger];
}

- (void)setupCallbackForVialerSIPLib {
    [VialerSIPLib sharedInstance].incomingCallBlock = ^(VSLCall * _Nonnull call) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:AppDelegateIncominCallNotification object:call];
        });
    };
}

@end

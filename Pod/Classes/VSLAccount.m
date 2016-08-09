//
//  VSLAccount.m
//  Copyright © 2015 Devhouse Spindle. All rights reserved.
//

#import "VSLAccount.h"

#import "Constants.h"
#import <CocoaLumberJack/CocoaLumberjack.h>
#import "NSError+VSLError.h"
#import "NSString+PJString.h"
#import <VialerPJSIP/pjsua.h>
#import "VSLCall.h"
#import "VSLEndpoint.h"
#import "VSLEndpointConfiguration.h"

static NSUInteger const VSLAccountRegistrationTimeoutInSeconds = 800;
static NSString * const VSLAccountErrorDomain = @"VialerSIPLib.VSLAccount";

@interface VSLAccount()
@property (readwrite, nonnull, nonatomic) VSLAccountConfiguration *accountConfiguration;
@property (strong, nonatomic) NSMutableArray *calls;
@property (readwrite, nonatomic) VSLAccountState accountState;
@property (copy, nonatomic) RegistrationCompletionBlock registrationCompletionBlock;
@property (assign) BOOL shouldReregister;
@property (assign) BOOL registrationInProgress;
@end

@implementation VSLAccount

- (instancetype)init {
    if (self = [super init]) {
        self.accountId = PJSUA_INVALID_ID;
    }
    return self;
}

#pragma mark - Properties

- (void)setAccountState:(VSLAccountState)accountState {
    if (_accountState != accountState) {
        DDLogDebug(@"AccountState will change from %@(%ld) to %@(%ld)", VSLAccountStateString(_accountState),
                   (long)_accountState, VSLAccountStateString(accountState), (long)accountState);
        _accountState = accountState;
    }
}

- (NSMutableArray *)calls {
    if (!_calls) {
        _calls = [NSMutableArray array];
    }
    return _calls;
}

- (BOOL)isAccountValid {
    return [[NSNumber numberWithInt:pjsua_acc_is_valid((pjsua_acc_id)self.accountId)] boolValue];
}

- (NSInteger)registrationStatus {
    if (self.accountId == PJSUA_INVALID_ID) {
        return 0;
    }
    pjsua_acc_info accountInfo;
    pj_status_t status;

    status = pjsua_acc_get_info((pjsua_acc_id)self.accountId, &accountInfo);
    if (status != PJ_SUCCESS) {
        return 0;
    }
    return accountInfo.status;
}

- (NSInteger)registrationExpiresTime {
    if (self.accountId == PJSUA_INVALID_ID) {
        return -1;
    }

    pjsua_acc_info accountInfo;
    pj_status_t status;

    status = pjsua_acc_get_info((pjsua_acc_id)self.accountId, &accountInfo);
    if (status != PJ_SUCCESS) {
        return -1;
    }
    return accountInfo.expires;
}

- (BOOL)isRegistered {
    return (self.registrationStatus / 100 == 2) && (self.registrationExpiresTime > 0);
}

- (BOOL)configureWithAccountConfiguration:(VSLAccountConfiguration * _Nonnull)accountConfiguration error:(NSError **)error {

    // If the endpoint has a tcp connection create a variable with the needed information.
    NSString *tcp = @"";
    if ([[VSLEndpoint sharedEndpoint].endpointConfiguration hasTCPConfiguration]) {
        tcp = @";transport=tcp";
    }

    pjsua_acc_config acc_cfg;
    pjsua_acc_config_default(&acc_cfg);

    // Add sip information to the pjsua account configuration.
    acc_cfg.id = [[accountConfiguration.sipAddress stringByAppendingString:tcp] prependSipUri].pjString;
    acc_cfg.reg_uri = [[accountConfiguration.sipDomain stringByAppendingString:tcp] prependSipUri].pjString;
    acc_cfg.register_on_acc_add = accountConfiguration.sipRegisterOnAdd ? PJ_TRUE : PJ_FALSE;
    acc_cfg.publish_enabled = accountConfiguration.sipPublishEnabled ? PJ_TRUE : PJ_FALSE;
    acc_cfg.reg_timeout = VSLAccountRegistrationTimeoutInSeconds;
    acc_cfg.drop_calls_on_reg_fail = accountConfiguration.dropCallOnRegistrationFailure ? PJ_TRUE : PJ_FALSE;

    // Add account information to the pjsua account configuration.
    acc_cfg.cred_count = 1;
    acc_cfg.cred_info[0].scheme = accountConfiguration.sipAuthScheme.pjString;
    acc_cfg.cred_info[0].realm = accountConfiguration.sipAuthRealm.pjString;
    acc_cfg.cred_info[0].username = accountConfiguration.sipAccount.pjString;
    acc_cfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acc_cfg.cred_info[0].data = accountConfiguration.sipPassword.pjString;
    acc_cfg.proxy_cnt = 0;

    // If a proxy server is present on the account configuration add this to pjsua account configuration.
    if (accountConfiguration.sipProxyServer) {
        acc_cfg.proxy_cnt = 1;
        acc_cfg.proxy[0] = [[accountConfiguration.sipProxyServer stringByAppendingString:tcp] prependSipUri].pjString;
    }

    int accountId;
    pj_status_t status = pjsua_acc_add(&acc_cfg, PJ_TRUE, &accountId);

    if (status == PJ_SUCCESS) {
        DDLogInfo(@"Account added succesfully");
        self.accountConfiguration = accountConfiguration;
        self.accountId = accountId;
        [[VSLEndpoint sharedEndpoint] addAccount:self];
    } else {
        if (error != NULL) {
            *error = [NSError VSLUnderlyingError:nil
               localizedDescriptionKey: NSLocalizedString(@"Could not configure VSLAccount", nil)
           localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                           errorDomain:VSLAccountErrorDomain
                             errorCode:VSLAccountErrorCannotConfigureAccount];
        }
        return NO;
    }

    if (!accountConfiguration.sipRegisterOnAdd) {
        self.accountState = VSLAccountStateOffline;
    }

    return YES;
}

- (void)removeAccount {
    pj_status_t status;

    status = pjsua_acc_del((pjsua_acc_id)self.accountId);
    if (status != PJ_SUCCESS) {
        DDLogError(@"Unable to remove account from sip server.");
    }
    [[VSLEndpoint sharedEndpoint] removeAccount:self];
}

- (void)registerAccountWithCompletion:(RegistrationCompletionBlock)completion {
    DDLogDebug(@"Account valid: %@", self.isAccountValid ? @"YES": @"NO");

    pjsua_acc_info info;
    pjsua_acc_get_info((pjsua_acc_id)self.accountId, &info);

    // If pjsua_acc_info.expires == -1 the account has a registration but, as it turns out,
    // this is not a valid check whether there is a registration in progress or not, at least,
    // not wit a connection loss. So, to track a registration in progress, an ivar is used.
    if (!self.registrationInProgress && info.expires == -1) {
        self.registrationInProgress = YES;
        DDLogVerbose(@"Sending registration for account: %@", [NSNumber numberWithInteger:self.accountId]);

        pj_status_t status;
        status = pjsua_acc_set_registration((pjsua_acc_id)self.accountId, PJ_TRUE);
        self.registrationInProgress = NO;

        if (status != PJ_SUCCESS) {
            DDLogError(@"Account registration failed");
            NSError *error = [NSError VSLUnderlyingError:nil
                                 localizedDescriptionKey:NSLocalizedString(@"Account registration failed", nil)
                             localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                                             errorDomain:VSLAccountErrorDomain
                                               errorCode:VSLAccountErrorRegistrationFailed];
            completion(NO, error);
        }
    } else {
        DDLogVerbose(@"VSLAccount registered or registration in progress, cannot sent another registration");
    }

    // Check if account is connected, otherwise set completionblock.
    if (self.accountState == VSLAccountStateConnected) {
        completion(YES, nil);
    } else {
        self.registrationCompletionBlock = completion;
    }
}

- (NSString *)description {
    NSMutableString *info = [[NSMutableString alloc] init];
    [info appendFormat:@"ID: %d\n", (pjsua_acc_id)self.accountId];
    [info appendFormat:@"State: %@(%d)\n", VSLAccountStateString(self.accountState), (int)self.accountState];
    [info appendFormat:@"Registered: %@\n",self.isRegistered ? @"YES" : @"NO"];
    [info appendFormat:@"Registration Status: %d\n", (int)self.registrationStatus];
    [info appendFormat:@"Registration Expires: %d\n", (int)self.registrationExpiresTime];
    [info appendFormat:@"Account valid %@\n", self.isAccountValid ? @"YES": @"NO"];

    return info;
}

- (BOOL)unregisterAccount:(NSError * _Nullable __autoreleasing *)error {

    if (!self.isRegistered) {
        return YES;
    }

    pj_status_t status;
    status = pjsua_acc_set_registration((pjsua_acc_id)self.accountId, PJ_FALSE);

    if (status != PJ_SUCCESS) {
        DDLogError(@"Account unregistration failed");
        if (error != nil) {
            *error = [NSError VSLUnderlyingError:nil
                         localizedDescriptionKey:NSLocalizedString(@"Account unregistration failed", nil)
                     localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                                     errorDomain:VSLAccountErrorDomain
                                       errorCode:VSLAccountErrorRegistrationFailed];
        }
        return NO;
    }
    DDLogInfo(@"Account unregistered succesfully");
    return YES;
}

- (void)reregisterAccount {
    if (self.calls.count > 0) {
        self.shouldReregister = YES;
        [self unregisterAccount:nil];
    }
}

- (void)accountStateChanged {
    pjsua_acc_info accountInfo;
    pjsua_acc_get_info((pjsua_acc_id)self.accountId, &accountInfo);

    pjsip_status_code code = accountInfo.status;

    if (code == 0 || accountInfo.expires == -1) {
        self.accountState = VSLAccountStateDisconnected;
        if (self.shouldReregister) {
            [self registerAccountWithCompletion:^(BOOL success, NSError * _Nullable error) {
                if (success) {
                    DDLogInfo(@"Account was re-registerd after a sucessfull unregister.");
                    self.shouldReregister = NO;
                    [self reinviteActiveCalls];
                } else {
                    DDLogWarn(@"Unable to re-register account");
                    self.shouldReregister = NO;
                }
            }];
        }
    } else if (PJSIP_IS_STATUS_IN_CLASS(code, 100) || PJSIP_IS_STATUS_IN_CLASS(code, 300)) {
        self.accountState = VSLAccountStateConnecting;
    } else if (PJSIP_IS_STATUS_IN_CLASS(code, 200)) {
        self.accountState = VSLAccountStateConnected;
        // Registration is succesfull.
        if (self.registrationCompletionBlock) {
            DDLogVerbose(@"Account registered succesfully");
            self.registrationCompletionBlock(YES, nil);
            self.registrationCompletionBlock = nil;
        }
    } else {
        self.accountState = VSLAccountStateDisconnected;
    }
}

#pragma mark - Calling methods

- (void)callNumber:(NSString *)number withCompletion:(void (^)(NSError * _Nullable, VSLCall * _Nullable))completion {
    NSError *callNumberError;
    VSLCall *call = [VSLCall callNumber:number withAccount:self error:&callNumberError];
    if (callNumberError) {
        NSError *error = [NSError VSLUnderlyingError:callNumberError
                   localizedDescriptionKey:NSLocalizedString(@"The call couldn't be setup.", nil)
               localizedFailureReasonError:nil
                               errorDomain:VSLAccountErrorDomain
                                 errorCode:VSLAccountErrorFailedCallingNumber];
        completion(error, nil);
    } else {
        completion(nil, call);
    }
}

- (void)addCall:(VSLCall *)call {
    [self.calls addObject:call];
}

- (VSLCall *)lookupCall:(NSInteger)callId {
    NSUInteger callIndex = [self.calls indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
        VSLCall *call = (VSLCall *)obj;
        if (call.callId == callId && call.callId != PJSUA_INVALID_ID) {
            return YES;
        }
        return NO;
    }];

    if (callIndex != NSNotFound) {
        return [self.calls objectAtIndex:callIndex];
    }
    return nil;
}

- (void)removeCall:(VSLCall *)call {
    [self.calls removeObject:call];

    // All calls are ended, we unregister the account.
    if ([self.calls count] == 0) {
        [self unregisterAccount:nil];
    }
}

- (void)removeAllCalls {
    for (VSLCall *call in self.calls) {
        [call hangup:nil];
        [self removeCall:call];
    }
}

- (VSLCall *)firstCall {
    if (self.calls.count > 0) {
        return self.calls[0];
    } else {
        return nil;
    }
}

- (NSArray <VSLCall *> *)allActiveCalls {
    NSMutableArray *activeCalls = [[NSMutableArray alloc] init];
    for (VSLCall *call in self.calls) {
        if (call.callState > VSLCallStateNull && call.callState < VSLCallStateDisconnected) {
            [activeCalls addObject:call];
        }
    }

    if ([activeCalls count]) {
        return activeCalls;
    } else {
        return nil;
    }
}

- (VSLCall *)firstActiveCall {
    for (VSLCall *call in [self allActiveCalls]) {
        if (call.callState > VSLCallStateNull && call.callState < VSLCallStateDisconnected) {
            return call;
        }
    }
    return nil;
}

- (void)reinviteActiveCalls {
    DDLogDebug(@"Reinviting calls");
    for (VSLCall *call in [self allActiveCalls]) {
        [call reinvite];
    }
}

@end

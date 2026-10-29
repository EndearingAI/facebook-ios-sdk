/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKAppEvents+Internal.h"

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import <objc/runtime.h>
#import <StoreKit/StoreKit.h>
#import <UIKit/UIApplication.h>

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import "FBSDKCoreKit-Swift.h"

#import "FBSDKATEPublishing.h"
#import "FBSDKAccessToken.h"
#import "FBSDKAppEventName.h"
#import "FBSDKAppEventName+Internal.h"
#import "FBSDKAppEventParameterName+Internal.h"
#import "FBSDKAppEventParameterProduct.h"
#import "FBSDKAppEventParameterProduct+Internal.h"
#import "FBSDKAppEventUserDataType.h"
#import "FBSDKAppEventsWKWebViewKeys.h"
#import "FBSDKAtePublishing.h"
#import "FBSDKConstants.h"
#import "FBSDKDynamicFrameworkLoader.h"
#import "FBSDKFeatureChecking.h"
#import "FBSDKGraphRequestFactoryProtocol.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKLogger.h"
#import "FBSDKLogging.h"
#import "FBSDKServerConfiguration.h"
#import "FBSDKUtility.h"

#if !TARGET_OS_TV

 #import "FBSDKEventBindingManager.h"
 #import "FBSDKHybridAppEventsScriptMessageHandler.h"

#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@protocol FBSDKCAPIReporter;

// Event parameter values internal to this file

NSString *const FBSDKGateKeeperAppEventsKillSwitch = @"app_events_killswitch";

NSString *const FBSDKAppEventsOverrideAppIDBundleKey = @"FacebookLoggingOverrideAppID";

//
// Push Notifications
//
// Activities Endpoint Parameter
static NSString *const FBSDKActivitesParameterPushDeviceToken = @"device_token";
// Event Parameter
// Payload Keys
static NSString *const FBSDKAppEventsPushPayloadKey = @"fb_push_payload";
static NSString *const FBSDKAppEventsPushPayloadCampaignKey = @"campaign";

#define NUM_LOG_EVENTS_TO_TRY_TO_FLUSH_AFTER 100
#define FLUSH_PERIOD_IN_SECONDS 15
#define USER_ID_USER_DEFAULTS_KEY @"com.facebook.sdk.appevents.userid"

#define FBUnityUtilityClassName "FBUnityUtility"
#define FBUnityUtilityUpdateBindingsSelector @"triggerUpdateBindings:"

static FBSDKAppEvents *_shared = nil;
static NSString *g_overrideAppID = nil;
static BOOL g_explicitEventsLoggedYet = NO;
static NSHashTable<FBSDKAppEvents *> *trackingInstances;
#if DEBUG
static BOOL g_hasLoggedManualImplicitLoggingWarning = NO;
#endif

@interface FBSDKAppEvents ()

@property (nonatomic) UIApplicationState applicationState;
@property (nullable, nonatomic, copy) NSString *pushNotificationsDeviceTokenString;
@property (nonatomic) dispatch_source_t flushTimer;
@property (nonatomic) BOOL isConfigured;
@property(nonatomic) int consentFlushPeriod;
@property(nonatomic) uint64_t installPendingGeneration;

@property (nonatomic) FBSDKServerConfiguration *serverConfiguration;
@property (nonatomic) FBSDKAppEventsState *appEventsState;
@property (nonatomic) BOOL _isUnityInitialized; // not publicly readable
@property (nonatomic) BOOL isObservingApplicationStatePersistence;

// Dependencies

@property (nullable, nonatomic) Class<FBSDKGateKeeperManaging> gateKeeperManager;
@property (nullable, nonatomic) id<FBSDKAppEventsConfigurationProviding> appEventsConfigurationProvider;
@property (nullable, nonatomic) id<FBSDKServerConfigurationProviding> serverConfigurationProvider;
@property (nullable, nonatomic) id<FBSDKGraphRequestFactory> graphRequestFactory;
@property (nullable, nonatomic) id<FBSDKFeatureChecking> featureChecker;
@property (nullable, nonatomic) id<FBSDKDataPersisting> primaryDataStore;
@property (nullable, nonatomic) Class<FBSDKLogging> logger;
@property (nullable, nonatomic) id<FBSDKSettings> settings;
@property (nullable, nonatomic) id<FBSDKPaymentObserving> paymentObserver;
@property (nullable, nonatomic) id<FBSDKSourceApplicationTracking, FBSDKTimeSpentRecording> timeSpentRecorder;
@property (nullable, nonatomic) id<FBSDKAppEventsStatePersisting> appEventsStateStore;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing> eventDeactivationParameterProcessor;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing> restrictiveDataFilterParameterProcessor;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing> protectedModeManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> bannedParamsManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> stdParamEnforcementManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> macaRuleMatchingManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> vvpConfigManager;
@property (nullable, nonatomic) id<FBSDKEventsProcessing> blocklistEventsManager;
@property (nullable, nonatomic) id<FBSDKEventsProcessing> redactedEventsManager;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing> sensitiveParamsManager;
@property (nullable, nonatomic) id<FBSDKATEPublisherCreating> atePublisherFactory;
@property (nullable, nonatomic) id<FBSDKATEPublishing> atePublisher;
@property (nullable, nonatomic) id<FBSDKAppEventsStateProviding> appEventsStateProvider;
@property (nullable, nonatomic) id<FBSDKAdvertiserIDProviding> advertiserIDProvider;
@property (nullable, nonatomic) id<FBSDKUserDataPersisting> userDataStore;
@property (nullable, nonatomic) id<FBSDKAppEventDropDetermining, FBSDKAppEventParametersExtracting, FBSDKAppEventsUtility, FBSDKLoggingNotifying> appEventsUtility;
@property (nullable, nonatomic) id<FBSDKInternalUtility> internalUtility;
@property (nullable, nonatomic) id<FBSDKCAPIReporter> capiReporter;
@property (nullable, nonatomic) id<FBSDKTransactionObserving> transactionObserver;
@property (nullable, nonatomic) id<FBSDKIAPFailedTransactionLoggingCreating> failedTransactionLoggingFactory;
@property (nullable, nonatomic) id<FBSDKIAPDedupeProcessing> iapDedupeProcessor;
@property (nullable, nonatomic) id<FBSDKIAPTransactionCaching> iapTransactionCache;

#if !TARGET_OS_TV
@property (nullable, nonatomic) id<FBSDKEventProcessing, FBSDKIntegrityParametersProcessorProvider> onDeviceMLModelManager;
@property (nullable, nonatomic) id<FBSDKMetadataIndexing> metadataIndexer;
@property (nullable, nonatomic) id<FBSDKAppEventsReporter> skAdNetworkReporter;
@property (nullable, nonatomic) id<FBSDKAppEventsReporter> skAdNetworkReporterV2;
@property (nullable, nonatomic) Class<FBSDKCodelessIndexing> codelessIndexer;
@property (nullable, nonatomic) Class<FBSDKSwizzling> swizzler;
@property (nullable, nonatomic) FBSDKEventBindingManager *eventBindingManager;
@property (nullable, nonatomic) Class<FBSDKAEMReporter> aemReporter;
#endif

@end

@implementation FBSDKAppEvents
{
  NSString *_userID;
}

#pragma mark - Object Lifecycle

+ (void)initialize
{
  if (self == FBSDKAppEvents.class) {
    g_overrideAppID = [[NSBundle.mainBundle objectForInfoDictionaryKey:FBSDKAppEventsOverrideAppIDBundleKey] copy];
    trackingInstances = [NSHashTable weakObjectsHashTable];
    [FBSDKTrackingConsent registerErasureHandler:^BOOL(NSError **error) {
      return [FBSDKAppEvents eraseTrackingStateWithError:error];
    }];
  }
}

- (instancetype)init
{
  return [self initWithFlushBehavior:FBSDKAppEventsFlushBehaviorAuto
                flushPeriodInSeconds:FLUSH_PERIOD_IN_SECONDS];
}

- (instancetype)initWithFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
                 flushPeriodInSeconds:(int)flushPeriodInSeconds
{
  self = [super init];
  if (self) {
    _flushBehavior = flushBehavior;

    _consentFlushPeriod = flushPeriodInSeconds;
    @synchronized(FBSDKTrackingConsent.lock)
    {
      [trackingInstances addObject:self];
    }

    self.applicationState = UIApplicationStateInactive;
  }

  return self;
}

- (void)startObservingApplicationStatePersistenceNotifications
{
  // Idempotent: this may be called during synchronous init and again from
  // startObservingApplicationLifecycleNotifications; register the persist observers only once.
  if (self.isObservingApplicationStatePersistence) {
    return;
  }
  self.isObservingApplicationStatePersistence = YES;

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationMovingFromActiveState)
   name:UIApplicationWillResignActiveNotification
   object:NULL];

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationTerminating)
   name:UIApplicationWillTerminateNotification
   object:NULL];
}

- (void)startObservingApplicationLifecycleNotifications
{
  // The persist-on-close observers are armed here too (idempotently) so a lone call still
  // registers the full set; when init arms them earlier this is a no-op.
  [self startObservingApplicationStatePersistenceNotifications];

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationDidBecomeActive)
   name:UIApplicationDidBecomeActiveNotification
   object:NULL];
}

- (void)dealloc
{
  [FBSDKUtility stopGCDTimer:self.flushTimer];
}

+ (BOOL)setTrackingEnabled:(BOOL)enabled error:(NSError **)error
{
  return [FBSDKTrackingConsent setEnabled:enabled error:error];
}

+ (BOOL)isTrackingEnabled
{
  return FBSDKTrackingConsent.isEnabled;
}

+ (BOOL)eraseTrackingStateWithError:(NSError **)error
{
  for (FBSDKAppEvents *instance in trackingInstances.allObjects)
  {
    [FBSDKUtility stopGCDTimer:instance.flushTimer];
    instance.flushTimer = nil;
    instance.appEventsState = nil;
    instance.installPendingGeneration = 0;
    instance->_userID = nil;
    instance->_pushNotificationsDeviceTokenString = nil;
    instance.serverConfiguration = nil;
  }
  [FBSDKAppEventsState eraseAllTrackingStates];
  [FBSDKTimeSpentData eraseAllTrackingState];
  [FBSDKAppEventsUtility.shared clearTrackingIdentifiers];
  [FBSDKGraphRequestMetadata cancelAllForTrackingWithdrawal];
  [FBSDKGraphRequestConnection cancelAllForTrackingWithdrawal];
  [[FBSDKGraphRequestQueue sharedInstance] clearForTrackingWithdrawal];

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSDictionary<NSString *, id> *stored = defaults.dictionaryRepresentation;
  for (NSString *key in stored)
  {
    if ([key hasPrefix:@"com.facebook.sdk:lastInstallResponse"])
    {
      // Retain only identity-free install-once bookkeeping, never a Graph response payload.
      [defaults setBool:YES forKey:key];
    }
    else if ([key hasPrefix:@"com.facebook.sdk:lastAttributionPing"])
    {
      NSString *appID = [key substringFromIndex:@"com.facebook.sdk:lastAttributionPing".length];
      NSString *successKey = [@"com.facebook.sdk:lastInstallResponse" stringByAppendingString:appID];
      if (stored[successKey])
      {
        [defaults setBool:YES forKey:key];
      }
      else
      {
        [defaults removeObjectForKey:key];
      }
    }
    else if ([key hasPrefix:@"com.facebook."] || [key hasPrefix:@"com.facebook:"] || [key hasPrefix:@"FBSDK"] ||
             [key hasPrefix:@"FBAEM"])
    {
      [defaults removeObjectForKey:key];
    }
  }
  BOOL erased = YES;
  NSError *firstError;
  NSString *library = [FBSDKBasicUtility persistenceFilePath:@""];
  NSError *directoryError;
  NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:library error:&directoryError];
  if (!files)
  {
    erased = NO;
    firstError = directoryError;
  }
  for (NSString *filename in files)
  {
    if ([filename hasPrefix:@"com-facebook-sdk-"] || [filename hasPrefix:@"com.facebook.sdk"] ||
        [filename hasPrefix:@"facebook_sdk"] || [filename hasPrefix:@"FBSDK"])
    {
      NSError *fileError;
      if (![FBSDKTrackingConsent eraseFileAtPath:[library stringByAppendingPathComponent:filename] error:&fileError])
      {
        erased = NO;
        firstError = firstError ?: fileError;
      }
    }
  }
  for (NSString *directory in @[ @"instrument", @"models" ])
  {
    NSError *fileError;
    if (![FBSDKTrackingConsent eraseFileAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:directory]
                                         error:&fileError])
    {
      erased = NO;
      firstError = firstError ?: fileError;
    }
  }
  if (![defaults synchronize])
  {
    erased = NO;
    firstError =
        firstError
            ?: [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSFileWriteUnknownError
                               userInfo:@{NSLocalizedDescriptionKey : @"Could not erase Meta tracking preferences."}];
  }
  if (!erased && error)
  {
    *error = firstError;
  }
  return erased;
}

#pragma mark - Public Methods

- (void)logEvent:(FBSDKAppEventName)eventName
{
  [self logEvent:eventName parameters:@{}];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
{
  [self logEvent:eventName
      valueToSum:valueToSum
      parameters:@{}];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self logEvent:eventName
      valueToSum:nil
      parameters:parameters
     accessToken:nil];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
      parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self logEvent:eventName
      valueToSum:@(valueToSum)
      parameters:parameters
     accessToken:nil];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(NSNumber *)valueToSum
      parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
     accessToken:(FBSDKAccessToken *)accessToken
{
  [self logEvent:eventName
           valueToSum:valueToSum
           parameters:parameters
   isImplicitlyLogged:[parameters[FBSDKAppEventParameterNameImplicitlyLogged] boolValue]
          accessToken:accessToken];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
{
  [self logPurchase:purchaseAmount
           currency:currency
         parameters:@{}];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self logPurchase:purchaseAmount
           currency:currency
         parameters:parameters
        accessToken:nil];
}

-(void)logFailedStoreKit2Purchase:(NSString *)productID
{
  if (@available(iOS 15.0, *)) {
    [[self.failedTransactionLoggingFactory createIAPFailedTransactionLogging] logFailedStoreKit2Purchase:productID];
  }
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
        accessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];
  [self checkForAutologgedPurchases];

  // A purchase event is just a regular logged event with a given event name
  // and treating the currency value as going into the parameters dictionary.
  NSDictionary<FBSDKAppEventParameterName, id> *newParameters;
  if (!parameters) {
    newParameters = @{ FBSDKAppEventParameterNameCurrency : currency };
  } else {
    newParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    [newParameters setValue:currency forKey:FBSDKAppEventParameterNameCurrency];
  }

  [self logEvent:FBSDKAppEventNamePurchased
      valueToSum:@(purchaseAmount)
      parameters:newParameters
     accessToken:accessToken];
}

/*
 * Push Notifications Logging
 */

- (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload
{
  [self logPushNotificationOpen:payload action:@""];
}

- (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload action:(NSString *)action
{
  [self validateConfiguration];

  NSDictionary<NSString *, id> *facebookPayload = payload[FBSDKAppEventsPushPayloadKey];
  if (!facebookPayload) {
    return;
  }
  NSString *campaign = facebookPayload[FBSDKAppEventsPushPayloadCampaignKey];
  if (campaign.length == 0) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"Malformed payload specified for logging a push notification open."];
    return;
  }

  NSMutableDictionary<FBSDKAppEventParameterName, id> *parameters = [@{FBSDKAppEventParameterNamePushCampaign : campaign} mutableCopy];
  if (action && action.length > 0) {
    [FBSDKTypeUtility dictionary:parameters setObject:action forKey:FBSDKAppEventParameterNamePushAction];
  }

  [self logEvent:FBSDKAppEventNamePushOpened parameters:parameters];
}

- (void)logProductItem:(NSString *)itemID
          availability:(FBSDKProductAvailability)availability
             condition:(FBSDKProductCondition)condition
           description:(NSString *)description
             imageLink:(NSString *)imageLink
                  link:(NSString *)link
                 title:(NSString *)title
           priceAmount:(double)priceAmount
              currency:(NSString *)currency
                  gtin:(nullable NSString *)gtin
                   mpn:(nullable NSString *)mpn
                 brand:(nullable NSString *)brand
            parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self validateConfiguration];

  if (itemID == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"itemID cannot be null"];
    return;
  } else if (description == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"description cannot be null"];
    return;
  } else if (imageLink == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"imageLink cannot be null"];
    return;
  } else if (link == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"link cannot be null"];
    return;
  } else if (title == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"title cannot be null"];
    return;
  } else if (currency == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"currency cannot be null"];
    return;
  } else if (gtin == nil && mpn == nil && brand == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"Either gtin, mpn or brand is required"];
    return;
  }

  NSMutableDictionary<FBSDKAppEventParameterName, id> *dict = [NSMutableDictionary dictionary];
  if (nil != parameters) {
    dict.valuesForKeysWithDictionary = parameters;
  }

  [FBSDKTypeUtility dictionary:dict setObject:itemID forKey:FBSDKAppEventParameterProductItemID];

  NSString *avail = nil;
  switch (availability) {
    case FBSDKProductAvailabilityInStock:
      avail = @"IN_STOCK"; break;
    case FBSDKProductAvailabilityOutOfStock:
      avail = @"OUT_OF_STOCK"; break;
    case FBSDKProductAvailabilityPreOrder:
      avail = @"PREORDER"; break;
    case FBSDKProductAvailabilityAvailableForOrder:
      avail = @"AVALIABLE_FOR_ORDER"; break;
    case FBSDKProductAvailabilityDiscontinued:
      avail = @"DISCONTINUED"; break;
  }
  if (avail) {
    [FBSDKTypeUtility dictionary:dict setObject:avail forKey:FBSDKAppEventParameterProductAvailability];
  }

  NSString *cond = nil;
  switch (condition) {
    case FBSDKProductConditionNew:
      cond = @"NEW"; break;
    case FBSDKProductConditionRefurbished:
      cond = @"REFURBISHED"; break;
    case FBSDKProductConditionUsed:
      cond = @"USED"; break;
  }
  if (cond) {
    [FBSDKTypeUtility dictionary:dict setObject:cond forKey:FBSDKAppEventParameterProductCondition];
  }

  [FBSDKTypeUtility dictionary:dict setObject:description forKey:FBSDKAppEventParameterProductDescription];
  [FBSDKTypeUtility dictionary:dict setObject:imageLink forKey:FBSDKAppEventParameterProductImageLink];
  [FBSDKTypeUtility dictionary:dict setObject:link forKey:FBSDKAppEventParameterProductLink];
  [FBSDKTypeUtility dictionary:dict setObject:title forKey:FBSDKAppEventParameterProductTitle];
  [FBSDKTypeUtility dictionary:dict setObject:[NSString stringWithFormat:@"%.3lf", priceAmount] forKey:FBSDKAppEventParameterProductPriceAmount];
  [FBSDKTypeUtility dictionary:dict setObject:currency forKey:FBSDKAppEventParameterProductPriceCurrency];
  if (gtin) {
    [FBSDKTypeUtility dictionary:dict setObject:gtin forKey:FBSDKAppEventParameterProductGTIN];
  }
  if (mpn) {
    [FBSDKTypeUtility dictionary:dict setObject:mpn forKey:FBSDKAppEventParameterProductMPN];
  }
  if (brand) {
    [FBSDKTypeUtility dictionary:dict setObject:brand forKey:FBSDKAppEventParameterProductBrand];
  }

  [self logEvent:FBSDKAppEventNameProductCatalogUpdate
      parameters:dict];
}

- (void)activateApp
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled)
    {
      return;
    }
    [self validateConfiguration];
    if (!self.flushTimer)
    {
      __weak FBSDKAppEvents *weakSelf = self;
      uint64_t generation = FBSDKTrackingConsent.generation;
      self.flushTimer = [FBSDKUtility startGCDTimerWithInterval:self.consentFlushPeriod block:^{
        @synchronized (FBSDKTrackingConsent.lock) {
          if ([FBSDKTrackingConsent isCurrentGeneration:generation]) {
            [weakSelf flushTimerFired:nil];
          }
        }
      }];
    }
    [self publishInstall];
    [self.timeSpentRecorder restore:YES];
  }
}

// Additional user data and push attribution are disabled in this distribution.
- (void)setPushNotificationsDeviceToken:(nullable NSData *)deviceToken
{
}
- (void)setPushNotificationsDeviceTokenString:(nullable NSString *)deviceTokenString
{
}

- (nullable NSString *)loggingOverrideAppID
{
  @synchronized (self) {
    return g_overrideAppID;
  }
}

- (void)setLoggingOverrideAppID:(nullable NSString *)appID
{
  [self validateConfiguration];


  if (![[self loggingOverrideAppID] isEqualToString:appID]) {
    if (g_explicitEventsLoggedYet) {
      [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                             logEntry:@"AppEvents.shared.loggingOverrideAppID should only be set prior to any events being logged."];
    }
    @synchronized (self) {
      g_overrideAppID = appID;
    }
  }
}

- (void)flush
{
  if (!FBSDKTrackingConsent.isEnabled)
  {
    return;
  }
  [self validateConfiguration];
  [self flushForReason:FBSDKAppEventsFlushReasonExplicit];
}

- (nullable NSString *)userID
{
  return nil;
}
- (void)setUserID:(nullable NSString *)userID
{
}

- (void)setUserEmail:(nullable NSString *)email
           firstName:(nullable NSString *)firstName
            lastName:(nullable NSString *)lastName
               phone:(nullable NSString *)phone
         dateOfBirth:(nullable NSString *)dateOfBirth
              gender:(nullable NSString *)gender
                city:(nullable NSString *)city
               state:(nullable NSString *)state
                 zip:(nullable NSString *)zip
             country:(nullable NSString *)country
{
  [self.userDataStore setUserEmail:email
           firstName:firstName
            lastName:lastName
               phone:phone
         dateOfBirth:dateOfBirth
              gender:gender
                city:city
               state:state
                 zip:zip
             country:country];
}

- (nullable NSString *)getUserData
{
  return [self.userDataStore getUserData];
}

- (void)clearUserData
{
  [self.userDataStore clearUserData];
}

- (void)setUserData:(nullable NSString *)data
            forType:(FBSDKAppEventUserDataType)type
{
  [self.userDataStore setUserData:data forType:type];
}

- (void)clearUserDataForType:(FBSDKAppEventUserDataType)type
{
  [self.userDataStore clearUserDataForType:type];
}

- (nullable NSString *)anonymousID
{
  return [FBSDKBasicUtility anonymousID];
}

#if !TARGET_OS_TV

- (void)augmentHybridWebView:(WKWebView *)webView
{
  [self validateConfiguration];

  if ([webView isKindOfClass:WKWebView.class]) {
    if (WKUserScript.class != nil) {
      WKUserContentController *controller = webView.configuration.userContentController;
      FBSDKHybridAppEventsScriptMessageHandler *scriptHandler = [[FBSDKHybridAppEventsScriptMessageHandler alloc] initWithEventLogger:self
                                                                                                                      loggingNotifier:self.appEventsUtility];
      [controller addScriptMessageHandler:scriptHandler name:FBSDKAppEventsWKWebViewMessagesHandlerKey];

      NSString *js = [NSString stringWithFormat:@"window.fbmq_%@={'sendEvent': function(pixel_id,event_name,custom_data){var msg={\"%@\":pixel_id, \"%@\":event_name,\"%@\":custom_data};window.webkit.messageHandlers[\"%@\"].postMessage(msg);}, 'getProtocol':function(){return \"%@\";}}",
                      self.appID,
                      FBSDKAppEventsWKWebViewMessagesPixelIDKey,
                      FBSDKAppEventsWKWebViewMessagesEventKey,
                      FBSDKAppEventsWKWebViewMessagesParamsKey,
                      FBSDKAppEventsWKWebViewMessagesHandlerKey,
                      FBSDKAppEventsWKWebViewMessagesProtocolKey
      ];

      [controller addUserScript:[[WKUserScript.class alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
  } else {
    [self.appEventsUtility logAndNotify:@"You must call augmentHybridWebView with WebKit linked to your project and a WKWebView instance"];
  }
}

#endif

- (void)setIsUnityInitialized:(BOOL)isUnityInitialized
{
  self._isUnityInitialized = isUnityInitialized;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
- (void)sendEventBindingsToUnity
{
  [self validateConfiguration];

  // Send event bindings to Unity only Unity is initialized
  if (self._isUnityInitialized
      && self.serverConfiguration
      && [NSJSONSerialization isValidJSONObject:self.serverConfiguration.eventBindings]
  ) {
    NSData *jsonData = [FBSDKTypeUtility dataWithJSONObject:self.serverConfiguration.eventBindings ?: @""
                                                    options:0
                                                      error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    Class classFBUnityUtility = objc_lookUpClass(FBUnityUtilityClassName);
    SEL updateBindingsSelector = NSSelectorFromString(FBUnityUtilityUpdateBindingsSelector);
    if ([classFBUnityUtility respondsToSelector:updateBindingsSelector]) {
      [classFBUnityUtility performSelector:updateBindingsSelector withObject:jsonString];
    }
  }
}

#pragma clang diagnostic pop

#pragma mark - Internal Methods

- (void)   configureWithGateKeeperManager:(nonnull Class<FBSDKGateKeeperManaging>)gateKeeperManager
           appEventsConfigurationProvider:(nonnull id<FBSDKAppEventsConfigurationProviding>)appEventsConfigurationProvider
              serverConfigurationProvider:(nonnull id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
                      graphRequestFactory:(nonnull id<FBSDKGraphRequestFactory>)graphRequestFactory
                           featureChecker:(nonnull id<FBSDKFeatureChecking>)featureChecker
                         primaryDataStore:(nonnull id<FBSDKDataPersisting>)primaryDataStore
                                   logger:(nonnull Class<FBSDKLogging>)logger
                                 settings:(nonnull id<FBSDKSettings>)settings
                          paymentObserver:(nonnull id<FBSDKPaymentObserving>)paymentObserver
                        timeSpentRecorder:(nonnull id<FBSDKSourceApplicationTracking, FBSDKTimeSpentRecording>)timeSpentRecorder
                      appEventsStateStore:(nonnull id<FBSDKAppEventsStatePersisting>)appEventsStateStore
      eventDeactivationParameterProcessor:(nonnull id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)eventDeactivationParameterProcessor
  restrictiveDataFilterParameterProcessor:(nonnull id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)restrictiveDataFilterParameterProcessor
                      atePublisherFactory:(nonnull id<FBSDKATEPublisherCreating>)atePublisherFactory
                   appEventsStateProvider:(nonnull id<FBSDKAppEventsStateProviding>)appEventsStateProvider
                     advertiserIDProvider:(nonnull id<FBSDKAdvertiserIDProviding>)advertiserIDProvider
                            userDataStore:(nonnull id<FBSDKUserDataPersisting>)userDataStore
                         appEventsUtility:(nonnull id<FBSDKAppEventDropDetermining, FBSDKAppEventParametersExtracting, FBSDKAppEventsUtility, FBSDKLoggingNotifying>)appEventsUtility
                          internalUtility:(nonnull id<FBSDKInternalUtility>)internalUtility
                             capiReporter:(id<FBSDKCAPIReporter>)capiReporter
                     protectedModeManager:(nonnull id<FBSDKAppEventsParameterProcessing>)protectedModeManager
                      bannedParamsManager:(nonnull id<FBSDKMACARuleMatching>)bannedParamsManager
               stdParamEnforcementManager:(nonnull id<FBSDKMACARuleMatching>)stdParamEnforcementManager
                 macaRuleMatchingManager:(nonnull id<FBSDKMACARuleMatching>)macaRuleMatchingManager
                        vvpConfigManager:(nonnull id<FBSDKMACARuleMatching>)vvpConfigManager
                   blocklistEventsManager:(nonnull id<FBSDKEventsProcessing>)blocklistEventsManager
                    redactedEventsManager:(nonnull id<FBSDKEventsProcessing>)redactedEventsManager
                   sensitiveParamsManager:(nonnull id<FBSDKAppEventsParameterProcessing>)sensitiveParamsManager
                      transactionObserver:(nonnull id<FBSDKTransactionObserving>)transactionObserver
          failedTransactionLoggingFactory:(nonnull id<FBSDKIAPFailedTransactionLoggingCreating>)failedTransactionLoggingFactory
                       iapDedupeProcessor:(nonnull id<FBSDKIAPDedupeProcessing>)iapDedupeProcessor
                      iapTransactionCache:(nonnull id<FBSDKIAPTransactionCaching>)iapTransactionCache
{
  self.gateKeeperManager = gateKeeperManager;
  self.appEventsConfigurationProvider = appEventsConfigurationProvider;
  self.serverConfigurationProvider = serverConfigurationProvider;
  self.graphRequestFactory = graphRequestFactory;
  self.featureChecker = featureChecker;
  self.primaryDataStore = primaryDataStore;
  self.logger = logger;
  self.settings = settings; // This must be set before using/changing `userID`
  self.paymentObserver = paymentObserver;
  self.timeSpentRecorder = timeSpentRecorder;
  self.appEventsStateStore = appEventsStateStore;
  self.eventDeactivationParameterProcessor = eventDeactivationParameterProcessor;
  self.restrictiveDataFilterParameterProcessor = restrictiveDataFilterParameterProcessor;
  self.atePublisherFactory = atePublisherFactory;
  self.appEventsStateProvider = appEventsStateProvider;
  self.advertiserIDProvider = advertiserIDProvider;
  self.userDataStore = userDataStore;
  self.appEventsUtility = appEventsUtility;
  self.internalUtility = internalUtility;
  self.capiReporter = capiReporter;
  self.protectedModeManager = protectedModeManager;
  self.bannedParamsManager = bannedParamsManager;
  self.stdParamEnforcementManager = stdParamEnforcementManager;
  self.macaRuleMatchingManager = macaRuleMatchingManager;
  self.vvpConfigManager = vvpConfigManager;
  self.blocklistEventsManager = blocklistEventsManager;
  self.redactedEventsManager = redactedEventsManager;
  self.sensitiveParamsManager = sensitiveParamsManager;
  self.transactionObserver = transactionObserver;
  self.failedTransactionLoggingFactory = failedTransactionLoggingFactory;
  self.iapDedupeProcessor = iapDedupeProcessor;
  self.iapTransactionCache = iapTransactionCache;

  self.isConfigured = YES;
}

#if !TARGET_OS_TV

- (void)configureNonTVComponentsWithOnDeviceMLModelManager:(nonnull id<FBSDKEventProcessing, FBSDKIntegrityParametersProcessorProvider>)modelManager
                                           metadataIndexer:(nonnull id<FBSDKMetadataIndexing>)metadataIndexer
                                       skAdNetworkReporter:(nullable id<FBSDKAppEventsReporter>)skAdNetworkReporter
                                       skAdNetworkReporterV2:(nullable id<FBSDKAppEventsReporter>)skAdNetworkReporterV2
                                           codelessIndexer:(nonnull Class<FBSDKCodelessIndexing>)codelessIndexer
                                                  swizzler:(nonnull Class<FBSDKSwizzling>)swizzler
                                               aemReporter:(nonnull Class<FBSDKAEMReporter>)aemReporter
{
  self.onDeviceMLModelManager = modelManager;
  self.metadataIndexer = metadataIndexer;
  self.skAdNetworkReporter = skAdNetworkReporter;
  self.skAdNetworkReporterV2 = skAdNetworkReporterV2;
  self.codelessIndexer = codelessIndexer;
  self.swizzler = swizzler;
  self.aemReporter = aemReporter;
}

#endif

- (void)logInternalEvent:(FBSDKAppEventName)eventName
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              parameters:@{}
      isImplicitlyLogged:isImplicitlyLogged];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:valueToSum
              parameters:@{}
      isImplicitlyLogged:isImplicitlyLogged];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:nil
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:nil];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self logInternalEvent:eventName
              valueToSum:nil
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:accessToken];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:@(valueToSum)
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:nil];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  if ([self.settings isAutoLogAppEventsEnabled]) {
    [self logEvent:eventName
             valueToSum:valueToSum
             parameters:parameters
     isImplicitlyLogged:isImplicitlyLogged
            accessToken:accessToken];
  }
}

- (void)logImplicitEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self logEvent:eventName
           valueToSum:valueToSum
           parameters:parameters
   isImplicitlyLogged:YES
          accessToken:accessToken];
}

+ (FBSDKAppEvents *)shared
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _shared = [self new];
  });
  return _shared;
}

- (void)flushForReason:(FBSDKAppEventsFlushReason)flushReason
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled || !self.appEventsState.events.count)
    {
      return;
    }
    FBSDKAppEventsState *state = [self.appEventsState copy];
    self.appEventsState = [self.appEventsStateProvider createStateWithToken:state.tokenString appID:state.appID];
    // Only the mutable state container crosses the queue. Withdrawal empties every
    // outstanding container synchronously, before the queued callback can execute.
    dispatch_async(dispatch_get_main_queue(), ^{
      [self flushOnMainQueue:state forReason:flushReason];
    });
  }
}

#pragma mark - Source Application Tracking

- (void)setSourceApplication:(NSString *)sourceApplication openURL:(NSURL *)url
{
  [self.timeSpentRecorder setSourceApplication:sourceApplication openURL:url];
}

- (void)setSourceApplication:(NSString *)sourceApplication isFromAppLink:(BOOL)isFromAppLink
{
  [self.timeSpentRecorder setSourceApplication:sourceApplication isFromAppLink:isFromAppLink];
}

- (void)registerAutoResetSourceApplication
{
  [self.timeSpentRecorder registerAutoResetSourceApplication];
}

#pragma mark - Private Methods
- (nullable NSString *)appID
{
  return self.loggingOverrideAppID ?: [self.settings appID];
}

- (void)publishInstall
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled)
    {
      return;
    }
    NSString *appID = self.appID;
    if (appID.length == 0)
    {
      return;
    }
    uint64_t generation = FBSDKTrackingConsent.generation;
    NSString *successKey = [@"com.facebook.sdk:lastInstallResponse" stringByAppendingString:appID];
    if ([self.primaryDataStore fb_objectForKey:successKey] || self.installPendingGeneration == generation)
    {
      return;
    }
    self.installPendingGeneration = generation;
    NSMutableDictionary<NSString *, NSString *> *params =
        [self.appEventsUtility activityParametersDictionaryForEvent:@"MOBILE_APP_INSTALL"
                                          shouldAccessAdvertisingID:YES
                                                             userID:nil
                                                           userData:nil];
    id<FBSDKGraphRequest> request =
        [self.graphRequestFactory createGraphRequestWithGraphPath:[appID stringByAppendingString:@"/activities"]
                                                       parameters:params
                                                      tokenString:nil
                                                       HTTPMethod:FBSDKHTTPMethodPOST
                                                            flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError |
                                                                  FBSDKGraphRequestFlagDisableErrorRecovery
                                                     forAppEvents:YES
                                useAlternativeDefaultDomainPrefix:NO];
    [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *requestError) {
      @synchronized(FBSDKTrackingConsent.lock)
      {
        if (![FBSDKTrackingConsent isCurrentGeneration:generation])
        {
          return;
        }
        self.installPendingGeneration = 0;
        if (!requestError)
        {
          [self.primaryDataStore fb_setBool:YES forKey:successKey];
          [self.primaryDataStore fb_setBool:YES
                                     forKey:[@"com.facebook.sdk:lastAttributionPing" stringByAppendingString:appID]];
        }
      }
    }];
  }
}

- (void)publishATE
{
  if (self.appID.length == 0) {
    return;
  }

  self.atePublisher = self.atePublisher ?: [self.atePublisherFactory createPublisherWithAppID:self.appID];

#if DEBUG
  [self.atePublisher publishATE];
#else
  __weak FBSDKAppEvents *weakSelf = self;
  fb_dispatch_on_main_thread(^(void) {
    [weakSelf.atePublisher publishATE];
  });
#endif
}

- (void)appendInstallTimestamp:(nonnull NSMutableDictionary<NSString *, NSString *> *)parameters
{
  if (@available(iOS 14.0, *)) {
    if (self.settings.isATETimeSufficientlyDelayed) {
      NSDate *ateTimestamp = self.settings.advertiserTrackingEnabledTimestamp;
      [FBSDKTypeUtility dictionary:parameters setObject:@([self.appEventsUtility convertToUnixTime:ateTimestamp]) forKey:@"install_timestamp"];
    } else {
      NSDate *installTimestamp = self.settings.installTimestamp;
      [FBSDKTypeUtility dictionary:parameters setObject:@([self.appEventsUtility convertToUnixTime:installTimestamp]) forKey:@"install_timestamp"];
    }
  }
}

#if !TARGET_OS_TV
- (void)enableCodelessEvents
{
  if (!self.swizzler) {
    return;
  }

  if (self.serverConfiguration.isCodelessEventsEnabled) {
    [self.codelessIndexer enable];

    if (!self.eventBindingManager) {
      self.eventBindingManager = [[FBSDKEventBindingManager alloc] initWithSwizzler:self.swizzler
                                                                        eventLogger:self];
    }

    if (self.internalUtility.isUnity) {
      [self sendEventBindingsToUnity];
    } else {
      FBSDKEventBindingManager *manager = [[FBSDKEventBindingManager alloc] initWithSwizzler:self.swizzler
                                                                                 eventLogger:self];
      [self.eventBindingManager updateBindings:[manager parseArray:self.serverConfiguration.eventBindings]];
    }
  }
}

#endif

// app events can use a server configuration up to 24 hours old to minimize network traffic.
- (void)fetchServerConfiguration:(nullable dispatch_block_t)callback
{
  // Remote feature/configuration flags cannot expand attribution collection.
  if (callback)
  {
    callback();
  }
}

- (nullable NSDictionary<NSString *, id> *)addImplicitPurchaseParameters:(nullable NSDictionary<FBSDKAppOperationalDataType, NSDictionary<NSString *, id> *> *)operationalParameters{
  NSMutableDictionary<FBSDKAppOperationalDataType, NSDictionary<NSString *, id> *> *params = [operationalParameters mutableCopy];
  if (params == nil) {
    params = [[NSMutableDictionary alloc] initWithDictionary:@{}];
  }
  NSMutableDictionary<NSString *, id> *iapParameters = [[params objectForKey:FBSDKAppOperationalDataTypeIAPParameters] mutableCopy];
  if (iapParameters == nil) {
    iapParameters = [[NSMutableDictionary alloc] initWithDictionary:@{}];
  }
  if (self.serverConfiguration) {
    [FBSDKTypeUtility dictionary:iapParameters setObject:self.serverConfiguration.implicitPurchaseLoggingEnabled ? @"1" : @"0" forKey:@"is_implicit_purchase_logging_enabled"];
    [FBSDKTypeUtility dictionary:iapParameters setObject:[self.settings isAutoLogAppEventsEnabled] ? @"1" : @"0" forKey:@"is_autolog_app_events_enabled"];
  }
  if (iapParameters != nil && iapParameters.count > 0) {
    [FBSDKTypeUtility dictionary:params setObject:iapParameters forKey:FBSDKAppOperationalDataTypeIAPParameters];
  }
  return [params copy];
}

- (void)    logEvent:(FBSDKAppEventName)eventName
          valueToSum:(NSNumber *)valueToSum
          parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
  isImplicitlyLogged:(BOOL)isImplicitlyLogged
         accessToken:(FBSDKAccessToken *)accessToken
{
  if (!isImplicitlyLogged && self.iapDedupeProcessor.isEnabled && [self.iapDedupeProcessor shouldDedupeEvent:eventName valueToSum:valueToSum parameters:parameters]) {
    [self.iapDedupeProcessor processManualEvent:eventName
                                     valueToSum:valueToSum
                                     parameters:parameters
                                    accessToken:accessToken
                          operationalParameters:nil];
  } else {
    [self doLogEvent:eventName
          valueToSum:valueToSum
          parameters:parameters
  isImplicitlyLogged:isImplicitlyLogged
         accessToken:accessToken
operationalParameters:nil];
    // Unless the behavior is set to only allow explicit flushing, we go ahead and flush, since purchase events
    // are relatively rare and relatively high value and worth getting across on wire right away.
    if (eventName == FBSDKAppEventNamePurchased && self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
    }
  }
}

- (void)doLogEvent:(FBSDKAppEventName)eventName
               valueToSum:(nullable NSNumber *)valueToSum
               parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
       isImplicitlyLogged:(BOOL)isImplicitlyLogged
              accessToken:(nullable FBSDKAccessToken *)accessToken
    operationalParameters:
        (nullable NSDictionary<FBSDKAppOperationalDataType, NSDictionary<NSString *, id> *> *)operationalParameters
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled || isImplicitlyLogged ||
        ![eventName isEqualToString:FBSDKAppEventNameActivatedApp])
    {
      return;
    }
    [self validateConfiguration];
    NSMutableDictionary<NSString *, id> *event = [NSMutableDictionary dictionaryWithDictionary:parameters ?: @{}];
    event[FBSDKAppEventParameterNameEventName] = eventName;
    event[FBSDKAppEventParameterNameLogTime] = @([self.appEventsUtility unixTimeNow]);
    if (!self.appEventsState) {
      self.appEventsState = [self.appEventsStateProvider createStateWithToken:nil appID:self.appID];
    }
    [self.appEventsState addEvent:event isImplicit:NO withOperationalParameters:nil];
    if (self.appEventsState.events.count > NUM_LOG_EVENTS_TO_TRY_TO_FLUSH_AFTER
        && self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEventThreshold];
    }
  }
}

// Saved events belong only to the current process and consent generation.
- (void)checkPersistedEvents
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled)
    {
      return;
    }
    for (FBSDKAppEventsState *saved in [self.appEventsStateStore retrievePersistedAppEventsStates])
    {
      if ([FBSDKTrackingConsent isCurrentGeneration:saved.trackingGeneration])
      {
        [self flushOnMainQueue:saved forReason:FBSDKAppEventsFlushReasonPersistedEvents];
      }
    }
  }
}

- (void)flushOnMainQueue:(FBSDKAppEventsState *)state forReason:(FBSDKAppEventsFlushReason)reason
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (![FBSDKTrackingConsent isCurrentGeneration:state.trackingGeneration] || state.events.count == 0 ||
        !state.appID.length)
    {
      return;
    }
    NSMutableDictionary<NSString *, NSString *> *params =
        [self.appEventsUtility activityParametersDictionaryForEvent:@"CUSTOM_APP_EVENTS"
                                          shouldAccessAdvertisingID:YES
                                                             userID:nil
                                                           userData:nil];
    params[@"custom_events"] =
        [state JSONStringForEventsAndOperationalParametersIncludingImplicitEvents:NO][@"custom_events"];
    id<FBSDKGraphRequest> request =
        [self.graphRequestFactory createGraphRequestWithGraphPath:[state.appID stringByAppendingString:@"/activities"]
                                                       parameters:params
                                                      tokenString:nil
                                                       HTTPMethod:FBSDKHTTPMethodPOST
                                                            flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError |
                                                                  FBSDKGraphRequestFlagDisableErrorRecovery
                                                     forAppEvents:YES
                                useAlternativeDefaultDomainPrefix:NO];
    [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *requestError) {
      [self handleActivitiesPostCompletion:requestError loggingEntry:nil appEventsState:state];
    }];
  }
}

- (void)handleActivitiesPostCompletion:(NSError *)error
                          loggingEntry:(NSString *)loggingEntry
                        appEventsState:(FBSDKAppEventsState *)state
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (![FBSDKTrackingConsent isCurrentGeneration:state.trackingGeneration])
    {
      return;
    }
    if (error && error.code != NSURLErrorCancelled)
    {
      if ([state isCompatibleWithAppEventsState:self.appEventsState])
      {
        [self.appEventsState addEventsFromAppEventState:state];
      }
      else
      {
        [self.appEventsStateStore persistAppEventsData:state];
      }
    }
  }
}

- (void)flushTimerFired:(id)arg
{
  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];
  if (self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
    [self flushForReason:FBSDKAppEventsFlushReasonTimer];
  }
}

- (void)applicationDidBecomeActive
{
  if (!FBSDKTrackingConsent.isEnabled)
  {
    return;
  }
  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  // This must happen here to avoid a race condition with the shared `Settings` object.
  [self fetchServerConfiguration:nil];

  [self checkPersistedEvents];

  // Restore time spent data, indicating that we're not being called from "activateApp".
  [self.timeSpentRecorder restore:NO];
}

- (void)applicationMovingFromActiveState
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled)
    {
      return;
    }
    // When moving from active state, we don't have time to wait for the result of a flush, so
    // just persist events to storage, and we'll process them at the next activation.
    FBSDKAppEventsState *copy = nil;
    @synchronized(FBSDKTrackingConsent.lock)
    {
      copy = [self.appEventsState copy];
      self.appEventsState = nil;
    }
    if (copy)
    {
      [self.appEventsStateStore persistAppEventsData:copy];
    }
    [self.timeSpentRecorder suspend];
  }
}

- (void)applicationTerminating
{
  NSString *appID = [self appID];
  if (appID) {
    NSString *lastAttributionPingString = [NSString stringWithFormat:@"com.facebook.sdk:lastAttributionPing%@", appID];
    NSString *lastInstallResponseKey = [NSString stringWithFormat:@"com.facebook.sdk:lastInstallResponse%@", appID];
    if (nil == [self.primaryDataStore fb_objectForKey:lastInstallResponseKey]) {
      [self.primaryDataStore fb_removeObjectForKey:lastAttributionPingString];
    }
  }
  [self applicationMovingFromActiveState];
}

- (void)checkForAutologgedPurchases
{
#if DEBUG
  if ([self.settings isAutoLogAppEventsEnabled] && self.serverConfiguration.implicitPurchaseLoggingEnabled && !g_hasLoggedManualImplicitLoggingWarning) {
    NSString *message = @"You are manually logging purchase events, but you also have auto-logging turned on. "
    "If you are manually logging In-App Purchases, we recommend just choosing one set up to avoid duplicate logging";
    NSLog(@"%@%@", @"<Warning>: ", message);
    g_hasLoggedManualImplicitLoggingWarning = YES;
  }
#endif
}

#pragma mark - Configuration Validation

- (void)validateConfiguration
{
#if DEBUG
  if (!self.isConfigured) {
    static NSString *const reason = @"As of v9.0, you must initialize the SDK prior to calling any methods or setting any properties. "
    "You can do this by calling `FBSDKApplicationDelegate`'s `application:didFinishLaunchingWithOptions:` method. "
    "Learn more: https://developers.facebook.com/docs/ios/getting-started"
    "If no `UIApplication` is available you can use `FBSDKApplicationDelegate`'s `initializeSDK` method.";
    @throw [NSException exceptionWithName:@"InvalidOperationException" reason:reason userInfo:nil];
  }
#endif
}

#pragma mark - Custom Audience

- (nullable id<FBSDKGraphRequest>)requestForCustomAudienceThirdPartyIDWithAccessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];

  if (accessToken == nil && (![[FBSDKDomainHandler sharedInstance] isDomainHandlingEnabled] || self.settings.isAdvertiserTrackingEnabled)) {
    accessToken = FBSDKAccessToken.currentAccessToken;
  }

  // Rules for how we use the attribution ID / advertiser ID for an 'custom_audience_third_party_id' Graph API request
  // 1) if the OS tells us that the user has Limited Ad Tracking, then just don't send, and return a nil in the token.
  // 2) if the app has set 'limitEventAndDataUsage', this effectively implies that app-initiated ad targeting shouldn't happen,
  // so use that data here to return nil as well.
  // 3) if we have a user session token, then no need to send attribution ID / advertiser ID back as the udid parameter
  // 4) otherwise, send back the udid parameter.
  if (self.settings.isEventDataUsageLimited) {
    return nil;
  }
  if ([[FBSDKDomainHandler sharedInstance] isDomainHandlingEnabled]) {
    if (![self.settings isAdvertiserTrackingEnabled]) {
      return nil;
    }
  } else if (self.settings.advertisingTrackingStatus == FBSDKAdvertisingTrackingDisallowed) {
    return nil;
  }

  NSString *tokenString = [self.appEventsUtility tokenStringToUseFor:accessToken
                                                loggingOverrideAppID:self.loggingOverrideAppID];
  NSString *udid = nil;
  if (!accessToken) {
    // We don't have a logged in user, so we need some form of udid representation. Prefer advertiser ID if
    // available. Note that this function only makes sense to be called in the context of advertising.
    udid = self.advertiserIDProvider.advertiserID;
    if (!udid) {
      // No udid, and no user token.  No point in making the request.
      return nil;
    }
  }

  NSDictionary<NSString *, id> *parameters = @{};
  if (udid) {
    parameters = @{ @"udid" : udid };
  }

  NSString *graphPath = [NSString stringWithFormat:@"%@/custom_audience_third_party_id", self.appID];

  id<FBSDKGraphRequest> request = [self.graphRequestFactory createGraphRequestWithGraphPath:graphPath
                                                                                 parameters:parameters
                                                                                tokenString:tokenString
                                                                                 HTTPMethod:FBSDKHTTPMethodGET
                                                                                      flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery
                                                          useAlternativeDefaultDomainPrefix:NO];
  return request;
}

#pragma clang diagnostic pop

#pragma mark - Testability

#if DEBUG

- (void)reset
{
  self.isConfigured = NO;
  self.applicationState = UIApplicationStateInactive;

  self.gateKeeperManager = nil;
  self.appEventsConfigurationProvider = nil;
  self.serverConfigurationProvider = nil;
  self.graphRequestFactory = nil;
  self.featureChecker = nil;
  self.primaryDataStore = nil;
  self.logger = nil;
  self.settings = nil;
  self.paymentObserver = nil;
  self.timeSpentRecorder = nil;
  self.appEventsStateStore = nil;
  self.eventDeactivationParameterProcessor = nil;
  self.restrictiveDataFilterParameterProcessor = nil;
  self.atePublisher = nil;
  self.atePublisherFactory = nil;
  self.appEventsStateProvider = nil;
  self.advertiserIDProvider = nil;
  self.userDataStore = nil;
  self.appEventsUtility = nil;
  self.internalUtility = nil;
  self.protectedModeManager = nil;
  self.bannedParamsManager = nil;
  self.stdParamEnforcementManager = nil;
  self.macaRuleMatchingManager = nil;
  self.vvpConfigManager = nil;
  self.blocklistEventsManager = nil;
  self.redactedEventsManager = nil;
  self.sensitiveParamsManager = nil;
  self.transactionObserver = nil;
  // The actual setter on here has a check to see if the SDK is initialized
  // This is not a useful check for tests so we can just reset the underlying
  // static var.
  @synchronized (self) {
    g_overrideAppID = nil;
  }

#if !TARGET_OS_TV
  self.onDeviceMLModelManager = nil;
  self.metadataIndexer = nil;
  self.skAdNetworkReporter = nil;
  self.skAdNetworkReporterV2 = nil;
  self.codelessIndexer = nil;
  self.swizzler = nil;
  self.eventBindingManager = nil;
  self.aemReporter = nil;
#endif
}

+ (void)setShared:(FBSDKAppEvents *)appEvents
{
  _shared = appEvents;
}

- (void)setFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
{
  [self validateConfiguration];
  _flushBehavior = flushBehavior;
}

#endif

@end

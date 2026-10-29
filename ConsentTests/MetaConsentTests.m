/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */
#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <zlib.h>
#import "FBSDKAppEvents+Internal.h"
#import "FBSDKAppEventName+Internal.h"
#import "MetaConsentTests-Swift.h"

@interface FBSDKAppEvents (ConsentContract)
+ (BOOL)setTrackingEnabled:(BOOL)enabled error:(NSError **)error;
+ (BOOL)isTrackingEnabled;
@end

static ATTrackingManagerAuthorizationStatus systemAuthorization;
static ATTrackingManagerAuthorizationStatus mockedAuthorization(id object, SEL selector)
{
  return systemAuthorization;
}
static NSMutableArray<NSURLRequest *> *recordedRequests;
static NSMutableArray<NSString *> *recordedBodies;
static NSMutableArray<NSURLProtocol *> *pendingRequests;
static BOOL networkOffline;
static BOOL holdResponses;
static NSString *failedRemovalPath;
static BOOL initialTrackingEnabled;
static NSString *initialAnonymousID;

@interface MetaLateTask : NSObject <FBSDKNetworkTask>
@property(nonatomic) NSURLSessionTaskState fb_state;
@end
@implementation MetaLateTask
- (void)fb_resume
{
  self.fb_state = NSURLSessionTaskStateRunning;
}
- (void)fb_cancel
{
  self.fb_state = NSURLSessionTaskStateCanceling;
}
@end

@interface MetaLateSession : NSObject <FBSDKURLSessionProviding>
@property(nonatomic, copy) FBSDKURLSessionTaskBlock completion;
@property(nonatomic) NSUInteger requests;
@end
@implementation MetaLateSession
- (id<FBSDKNetworkTask>)fb_dataTaskWithRequest:(NSURLRequest *)request
                             completionHandler:(FBSDKURLSessionTaskBlock)completion
{
  self.requests++;
  self.completion = completion;
  return [MetaLateTask new];
}
@end

@interface MetaConsentURLProtocol : NSURLProtocol
+ (void)finishPending;
@end
@implementation MetaConsentURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
  return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
  return request;
}
- (void)startLoading
{
  @synchronized(MetaConsentURLProtocol.class)
  {
    [recordedRequests addObject:self.request];
    NSData *body = self.request.HTTPBody;
    if (!body && self.request.HTTPBodyStream)
    {
      NSInputStream *stream = self.request.HTTPBodyStream;
      NSMutableData *data = [NSMutableData new];
      [stream open];
      uint8_t buffer[4096];
      NSInteger count;
      while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
        [data appendBytes:buffer length:count];
      [stream close];
      body = data;
    }
    if ([[self.request valueForHTTPHeaderField:@"Content-Encoding"] isEqualToString:@"gzip"])
    {
      z_stream stream = {0};
      stream.next_in = (Bytef *)body.bytes;
      stream.avail_in = (uInt)body.length;
      NSMutableData *data = [NSMutableData new];
      if (inflateInit2(&stream, 15 + 32) == Z_OK)
      {
        int status;
        do
        {
          uint8_t buffer[4096];
          stream.next_out = buffer;
          stream.avail_out = sizeof(buffer);
          status = inflate(&stream, Z_NO_FLUSH);
          [data appendBytes:buffer length:sizeof(buffer) - stream.avail_out];
        } while (status == Z_OK);
        inflateEnd(&stream);
        body = data;
      }
    }
    [recordedBodies addObject:[[NSString alloc] initWithData:body ?: NSData.data encoding:NSUTF8StringEncoding] ?: @""];
    if (holdResponses)
    {
      [pendingRequests addObject:self];
      return;
    }
  }
  [self complete];
}
- (void)complete
{
  if (networkOffline)
  {
    [self.client URLProtocol:self
            didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                 code:NSURLErrorNotConnectedToInternet
                                             userInfo:nil]];
    return;
  }
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                            statusCode:200
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:@{@"Content-Type" : @"application/json"}];
  NSData *data = [@"{\"success\":true,\"data\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
  [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  [self.client URLProtocol:self didLoadData:data];
  [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading
{
  @synchronized(MetaConsentURLProtocol.class)
  {
    [pendingRequests removeObject:self];
  }
}
+ (void)finishPending
{
  NSArray *requests;
  @synchronized(self)
  {
    requests = pendingRequests.copy;
    [pendingRequests removeAllObjects];
  }
  for (MetaConsentURLProtocol *request in requests)
    [request complete];
}
@end

@interface MetaConsentTests : XCTestCase
@end
@implementation MetaConsentTests
static IMP originalAuthorization;
static IMP originalConfiguration;
static IMP originalRemoval;
+ (void)setUp
{
  [super setUp];
  if ([FBSDKAppEvents respondsToSelector:@selector(isTrackingEnabled)])
  {
    initialTrackingEnabled = FBSDKAppEvents.isTrackingEnabled;
    initialAnonymousID = FBSDKAppEvents.shared.anonymousID;
  }
  originalAuthorization = method_setImplementation(
      class_getClassMethod(ATTrackingManager.class, @selector(trackingAuthorizationStatus)), (IMP)mockedAuthorization);
  Method configuration = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
  originalConfiguration =
      method_setImplementation(configuration, imp_implementationWithBlock(^NSURLSessionConfiguration *(id object) {
                                 NSURLSessionConfiguration *config =
                                     NSURLSessionConfiguration.ephemeralSessionConfiguration;
                                 config.protocolClasses = @[ MetaConsentURLProtocol.class ];
                                 return config;
                               }));
  originalRemoval = method_setImplementation(
      class_getInstanceMethod(NSFileManager.class, @selector(removeItemAtPath:error:)),
      imp_implementationWithBlock(^BOOL(NSFileManager *manager, NSString *path, NSError **error) {
        if ([path isEqualToString:failedRemovalPath])
        {
          if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
          return NO;
        }
        return ((BOOL (*)(id, SEL, NSString *, NSError **))originalRemoval)(manager, @selector(removeItemAtPath:error:),
                                                                            path, error);
      }));
}
+ (void)tearDown
{
  method_setImplementation(class_getClassMethod(ATTrackingManager.class, @selector(trackingAuthorizationStatus)),
                           originalAuthorization);
  IMP replacement = method_setImplementation(
      class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration)),
      originalConfiguration);
  imp_removeBlock(replacement);
  replacement = method_setImplementation(
      class_getInstanceMethod(NSFileManager.class, @selector(removeItemAtPath:error:)), originalRemoval);
  imp_removeBlock(replacement);
  [super tearDown];
}
- (void)setUp
{
  [super setUp];
  systemAuthorization = ATTrackingManagerAuthorizationStatusAuthorized;
  networkOffline = NO;
  holdResponses = NO;
  failedRemovalPath = nil;
  @synchronized(MetaConsentURLProtocol.class)
  {
    recordedRequests = [NSMutableArray new];
    recordedBodies = [NSMutableArray new];
    pendingRequests = [NSMutableArray new];
  }
  if ([FBSDKAppEvents respondsToSelector:@selector(setTrackingEnabled:error:)])
  {
    XCTAssertTrue([FBSDKAppEvents setTrackingEnabled:NO error:nil]);
  }
  else
  {
    [ConsentTestBootstrap initializeSDK];
    FBSDKSettings.sharedSettings.isAdvertiserIDCollectionEnabled = NO;
    FBSDKSettings.sharedSettings.isAdvertiserTrackingEnabled = NO;
  }
  [self drain];
}
- (void)tearDown
{
  [self setConsent:NO];
  [super tearDown];
}
- (void)drain
{
  XCTestExpectation *settled = [self expectationWithDescription:@"native queues settle"];
  settled.inverted = YES;
  [self waitForExpectations:@[ settled ] timeout:0.2];
}
- (void)setConsent:(BOOL)enabled
{
  if ([FBSDKAppEvents respondsToSelector:@selector(setTrackingEnabled:error:)])
  {
    NSError *error;
    XCTAssertTrue([FBSDKAppEvents setTrackingEnabled:enabled error:&error]);
    XCTAssertNil(error);
  }
  else
  {
    FBSDKSettings.sharedSettings.isAdvertiserIDCollectionEnabled = enabled;
    FBSDKSettings.sharedSettings.isAdvertiserTrackingEnabled = enabled;
  }
}
- (NSUInteger)requestCount
{
  @synchronized(MetaConsentURLProtocol.class)
  {
    return recordedRequests.count;
  }
}
- (void)testDeniedInitializationAndActivationHaveNoNetworkingOrIdentity
{
  XCTAssertTrue([FBSDKAppEvents respondsToSelector:@selector(setTrackingEnabled:error:)]);
  [ConsentTestBootstrap initializeSDK];
  [FBSDKAppEvents.shared activateApp];
  [FBSDKAppEvents.shared flush];
  [self drain];
  XCTAssertEqual(self.requestCount, 0u);
  XCTAssertNil(FBSDKAppEvents.shared.anonymousID);
}
- (void)testAProcessStartsDeniedBeforeInitializationOrJavaScript
{
  XCTAssertFalse(initialTrackingEnabled);
  XCTAssertNil(initialAnonymousID);
}
- (void)testOfflineActivateWithdrawalThenReconnectCannotSendOrReplay
{
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  networkOffline = YES;
  [FBSDKAppEvents.shared activateApp];
  [FBSDKAppEvents.shared logEvent:FBSDKAppEventNameActivatedApp
                       parameters:@{@"consent_marker" : @"revoked-offline-open"}];
  [FBSDKAppEvents.shared flush];
  [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
  [self drain];
  XCTAssertGreaterThan(self.requestCount, 0u);
  NSString *oldID = FBSDKAppEvents.shared.anonymousID;
  XCTAssertNotNil(oldID);
  [self setConsent:NO];
  NSUInteger boundary = self.requestCount;
  networkOffline = NO;
  [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
  [FBSDKAppEvents.shared activateApp];
  [FBSDKAppEvents.shared flush];
  [self drain];
  XCTAssertEqual(self.requestCount, boundary);
  XCTAssertNil(FBSDKAppEvents.shared.anonymousID);
  NSString *file = [FBSDKBasicUtility persistenceFilePath:@"com-facebook-sdk-AppEventsPersistedEvents.json"];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:file]);
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  XCTAssertNotEqualObjects(oldID, FBSDKAppEvents.shared.anonymousID);
  [FBSDKAppEvents.shared activateApp];
  [FBSDKAppEvents.shared flush];
  [self drain];
  @synchronized(MetaConsentURLProtocol.class)
  {
    for (NSUInteger i = boundary; i < recordedBodies.count; i++)
    {
      XCTAssertFalse([recordedBodies[i] containsString:@"revoked-offline-open"]);
    }
  }
}
- (void)testOSRevocationBlocksNativeTransportBeforeJavaScriptOrForeground
{
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  [self drain];
  systemAuthorization = ATTrackingManagerAuthorizationStatusDenied;
  NSUInteger boundary = self.requestCount;
  [FBSDKAppEvents.shared activateApp];
  [FBSDKAppEvents.shared flush];
  [self drain];
  XCTAssertEqual(self.requestCount, boundary);
  XCTAssertNil(FBSDKAppEvents.shared.anonymousID);
  XCTAssertNil(FBSDKAppEventsUtility.shared.advertiserID);
}
- (void)testWithdrawalCancelsHeldNativeRequestAndSettlesExactlyOnce
{
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  holdResponses = YES;
  __block NSUInteger completions = 0;
  __block NSError *resultError;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
  FBSDKURLSessionTask *task = [[FBSDKURLSessionTask alloc]
        initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://graph.facebook.com/consent-test"]]
            fromSession:session
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        completions++;
        resultError = error;
      }];
  [task start];
  [self drain];
  [self setConsent:NO];
  [self drain];
  XCTAssertEqual(completions, 1u);
  XCTAssertNotNil(resultError);
  holdResponses = NO;
  [MetaConsentURLProtocol finishPending];
  [self drain];
  XCTAssertEqual(completions, 1u);
  [session invalidateAndCancel];
}
- (void)testDeniedAndRepeatedInitializationAlwaysSettleCompletion
{
  __block NSUInteger completions = 0;
  [ConsentTestBootstrap initializeSDKWithCompletion:^{
    completions++;
  }];
  XCTAssertEqual(completions, 1u);
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDKWithCompletion:^{
    completions++;
  }];
  [ConsentTestBootstrap initializeSDKWithCompletion:^{
    completions++;
  }];
  [self setConsent:NO];
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDKWithCompletion:^{
    completions++;
  }];
  XCTAssertEqual(completions, 4u);
}
- (void)testGrantRequiresCurrentActualATT
{
  systemAuthorization = ATTrackingManagerAuthorizationStatusDenied;
  NSError *error;
  XCTAssertFalse([FBSDKAppEvents setTrackingEnabled:YES error:&error]);
  XCTAssertNotNil(error);
  XCTAssertFalse(FBSDKAppEvents.isTrackingEnabled);
  XCTAssertNil(FBSDKBasicUtility.anonymousID);
}
- (void)testSuspendedTaskAndLateDuplicateCallbacksCannotCrossRegrant
{
  [self setConsent:YES];
  MetaLateSession *session = [MetaLateSession new];
  __block NSUInteger completions = 0;
  __block NSError *receivedError;
  NSURLRequest *request =
      [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://graph.facebook.com/consent-test"]];
  FBSDKURLSessionTask *suspended =
      [[FBSDKURLSessionTask alloc] initWithRequest:request
                                       fromSession:session
                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                   completions++;
                                   receivedError = error;
                                 }];
  [self setConsent:NO];
  XCTAssertEqual(completions, 1u);
  [self setConsent:YES];
  [suspended start];
  XCTAssertEqual(session.requests, 0u);
  FBSDKURLSessionTask *active =
      [[FBSDKURLSessionTask alloc] initWithRequest:request
                                       fromSession:session
                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                   completions++;
                                   receivedError = error;
                                 }];
  [active start];
  XCTAssertEqual(session.requests, 1u);
  [self setConsent:NO];
  XCTAssertEqual(completions, 2u);
  XCTAssertNotNil(receivedError);
  [self setConsent:YES];
  session.completion([@"late tracking response" dataUsingEncoding:NSUTF8StringEncoding], nil, nil);
  session.completion(nil, nil, nil);
  XCTAssertEqual(completions, 2u);
}
- (void)testDeniedTaskSettlesWithoutRetainingOrCreatingNativeRequest
{
  MetaLateSession *session = [MetaLateSession new];
  __block NSUInteger completions = 0;
  FBSDKURLSessionTask *task = [[FBSDKURLSessionTask alloc]
        initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://graph.facebook.com/consent-test"]]
            fromSession:session
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        completions++;
        XCTAssertNotNil(error);
      }];
  [task start];
  [task cancel];
  [task start];
  XCTAssertEqual(completions, 1u);
  XCTAssertEqual(session.requests, 0u);
}
- (void)testWithdrawalErasesAllOutstandingStatePayloadReferencesImmediately
{
  [self setConsent:YES];
  __weak NSString *weakPayload;
  FBSDKAppEventsState *state = [[FBSDKAppEventsState alloc] initWithToken:@"old-user-token" appID:@"123456"];
  @autoreleasepool
  {
    NSMutableString *payload = [NSMutableString stringWithString:@"old queued app-open payload"];
    weakPayload = payload;
    [state addEvent:@{@"marker" : payload} isImplicit:NO withOperationalParameters:nil];
  }
  XCTAssertNotNil(weakPayload);
  [self setConsent:NO];
  XCTAssertNil(weakPayload);
  XCTAssertEqual(state.events.count, 0u);
  XCTAssertNil(state.tokenString);
}
- (void)testErasureFailureDeniesBeforeReportingErrorAndBlocksRegrant
{
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  NSString *path = [FBSDKBasicUtility persistenceFilePath:@"com-facebook-sdk-AppEventsPersistedEvents.json"];
  XCTAssertTrue([[@"legacy events" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
  failedRemovalPath = path;
  NSError *error;
  XCTAssertFalse([FBSDKAppEvents setTrackingEnabled:NO error:&error]);
  XCTAssertNotNil(error);
  XCTAssertFalse(FBSDKAppEvents.isTrackingEnabled);
  XCTAssertNil(FBSDKAppEvents.shared.anonymousID);
  XCTAssertFalse([FBSDKAppEvents setTrackingEnabled:YES error:&error]);
  XCTAssertFalse(FBSDKAppEvents.isTrackingEnabled);
  failedRemovalPath = nil;
  [self setConsent:NO];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}
- (void)testExplicitAppOpenWorksWithAutoLoggingDisabledAndHasNoExtraData
{
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  FBSDKSettings.sharedSettings.isAutoLogAppEventsEnabled = YES;
  FBSDKSettings.sharedSettings.isSKAdNetworkReportEnabled = YES;
  XCTAssertFalse([ConsentTestBootstrap optionalCollectionEnabled]);
  [FBSDKAppEvents.shared logEvent:@"fb_mobile_purchase" parameters:@{@"purchase_marker" : @"must-not-collect"}];
  [FBSDKAppEvents.shared activateApp];
  [FBSDKAppEvents.shared flush];
  [self drain];
  BOOL foundOpen = NO;
  @synchronized(MetaConsentURLProtocol.class)
  {
    for (NSString *body in recordedBodies)
    {
      foundOpen |= [body containsString:FBSDKAppEventNameActivatedApp];
      for (NSString *key in @[
             @"extinfo", @"app_user_id", @"url_schemes", @"operational_parameters", @"_ui", @"session_id",
             @"receipt_data", @"must-not-collect"
           ])
      {
        XCTAssertFalse([body containsString:key], @"Unexpected extra data %@", key);
      }
    }
    for (NSURLRequest *request in recordedRequests)
    {
      XCTAssertTrue([request.URL.path hasSuffix:@"/activities"], @"Unexpected SDK request: %@", request.URL);
    }
  }
  XCTAssertTrue(foundOpen);
}
- (void)testSuccessfulInstallRetainsOnlyScalarBookkeepingAcrossFreshIdentity
{
  NSString *key = @"com.facebook.sdk:lastInstallResponse123456";
  [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  NSString *oldID = FBSDKAppEvents.shared.anonymousID;
  [FBSDKAppEvents.shared activateApp];
  [self drain];
  XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults objectForKey:key], @YES);
  [self setConsent:NO];
  [self setConsent:YES];
  XCTAssertNotEqualObjects(oldID, FBSDKAppEvents.shared.anonymousID);
  [FBSDKAppEvents.shared activateApp];
  [self drain];
  NSUInteger installs = 0;
  for (NSString *body in recordedBodies)
    installs += [body containsString:@"MOBILE_APP_INSTALL"];
  XCTAssertEqual(installs, 1u);
}
- (void)testQueuedGraphRequestIsPurgedAndCancelledOnceBeforeRegrant
{
  [self setConsent:YES];
  [ConsentTestBootstrap initializeSDK];
  __block NSUInteger completions = 0;
  FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc] initWithGraphPath:@"123456/activities"
                                                                 parameters:@{@"marker" : @"queued-old-consent"}];
  [[FBSDKGraphRequestQueue sharedInstance]
      enqueueRequest:request
          completion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
            completions++;
            XCTAssertNotNil(error);
          }];
  [self setConsent:NO];
  XCTAssertEqual(completions, 1u);
  XCTAssertEqual(request.parameters.count, 0u);
  [self setConsent:YES];
  [[FBSDKGraphRequestQueue sharedInstance] flush];
  [self drain];
  XCTAssertEqual(self.requestCount, 0u);
  XCTAssertEqual(completions, 1u);
}
- (void)testCancellationCallbackCannotRegrantDuringWithdrawal
{
  [self setConsent:YES];
  MetaLateSession *session = [MetaLateSession new];
  __block BOOL nestedGrantAllowed = YES;
  FBSDKURLSessionTask *task = [[FBSDKURLSessionTask alloc]
        initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://graph.facebook.com/consent-test"]]
            fromSession:session
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSError *grantError;
        nestedGrantAllowed = [FBSDKAppEvents setTrackingEnabled:YES error:&grantError];
        XCTAssertNotNil(grantError);
      }];
  [task start];
  [self setConsent:NO];
  XCTAssertFalse(nestedGrantAllowed);
  XCTAssertFalse(FBSDKAppEvents.isTrackingEnabled);
}

@end

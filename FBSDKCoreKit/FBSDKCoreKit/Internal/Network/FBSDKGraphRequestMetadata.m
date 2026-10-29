/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKGraphRequestMetadata.h"

#import "FBSDKGraphRequestProtocol.h"
#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>

static NSHashTable<FBSDKGraphRequestMetadata *> *trackingMetadata;

@interface FBSDKGraphRequestMetadata ()
@property(nonatomic) BOOL completionDelivered;
@end

@implementation FBSDKGraphRequestMetadata

- (instancetype)initWithRequest:(id<FBSDKGraphRequest>)request
              completionHandler:(FBSDKGraphRequestCompletion)handler
                batchParameters:(NSDictionary<NSString *, id> *)batchParameters
{
  if ((self = [super init])) {
    @synchronized(FBSDKTrackingConsent.lock)
    {
      if (!trackingMetadata)
      {
        trackingMetadata = [NSHashTable weakObjectsHashTable];
      }
      [trackingMetadata addObject:self];
      _trackingGeneration = FBSDKTrackingConsent.generation;
      _request = request;
      _batchParameters = [batchParameters copy];
      _completionHandler = [handler copy];
    }
  }
  return self;
}

- (void)invokeCompletionHandlerForConnection:(id<FBSDKGraphRequestConnecting>)connection
                                 withResults:(nullable id)results
                                       error:(nullable NSError *)error
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (self.completionDelivered)
    {
      return;
    }
    self.completionDelivered = YES;
    FBSDKGraphRequestCompletion completion = self.completionHandler;
    self.completionHandler = nil;
    if (![FBSDKTrackingConsent isCurrentGeneration:self.trackingGeneration])
    {
      results = nil;
      error = FBSDKTrackingConsent.cancellationError;
    }
    self.request.parameters = @{};
    self.batchParameters = nil;
    if (completion)
    {
      completion(connection, results, error);
    }
    self.request = nil;
  }
}

+ (void)cancelAllForTrackingWithdrawal
{
  for (FBSDKGraphRequestMetadata *metadata in trackingMetadata.allObjects)
  {
    [metadata invokeCompletionHandlerForConnection:nil withResults:nil error:FBSDKTrackingConsent.cancellationError];
  }
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@: %p, batchParameters: %@, completionHandler: %@, request: %@>",
          NSStringFromClass(self.class),
          self,
          self.batchParameters,
          self.completionHandler,
          self.request.formattedDescription];
}

@end

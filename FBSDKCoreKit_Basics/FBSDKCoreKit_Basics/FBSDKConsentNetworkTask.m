/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKConsentNetworkTask.h"

#import <FBSDKCoreKit_Basics/FBSDKTrackingConsent.h>

@interface FBSDKConsentNetworkTask ()
@property(nullable, nonatomic) NSURLRequest *request;
@property(nullable, nonatomic) id<FBSDKURLSessionProviding> session;
@property(nullable, nonatomic) id<FBSDKNetworkTask> underlyingTask;
@property(nullable, nonatomic, copy) void (^completion)(NSData *, NSURLResponse *, NSError *);
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL started;
@end

@implementation FBSDKConsentNetworkTask

- (instancetype)initWithRequest:(NSURLRequest *)request
                        session:(id<FBSDKURLSessionProviding>)session
                     completion:(void (^)(NSData *, NSURLResponse *, NSError *))completion
{
  if ((self = [super init]))
  {
    @synchronized(FBSDKTrackingConsent.lock)
    {
      _completion = [completion copy];
      _generation = FBSDKTrackingConsent.generation;
      if (FBSDKTrackingConsent.isEnabled)
      {
        _request = [request copy];
        _session = session;
        [FBSDKTrackingConsent registerTask:self];
      }
      else
      {
        [self finishWithData:nil response:nil error:FBSDKTrackingConsent.cancellationError];
      }
    }
  }
  return self;
}

- (NSURLSessionTaskState)fb_state
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    return self.finished ? NSURLSessionTaskStateCompleted
                         : (self.underlyingTask ? self.underlyingTask.fb_state : NSURLSessionTaskStateSuspended);
  }
}

- (void)fb_resume
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (self.finished || self.started)
    {
      return;
    }
    self.started = YES;
    if (!self.request || ![FBSDKTrackingConsent isCurrentGeneration:self.generation])
    {
      [self finishWithData:nil response:nil error:FBSDKTrackingConsent.cancellationError];
      return;
    }
    void (^completion)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
          @synchronized(FBSDKTrackingConsent.lock)
          {
            if (![FBSDKTrackingConsent isCurrentGeneration:self.generation])
            {
              data = nil;
              response = nil;
              error = FBSDKTrackingConsent.cancellationError;
            }
            [self finishWithData:data response:response error:error];
          }
        };
    // Bypass our NSURLSession category exactly once; custom providers keep their documented protocol.
    if ([self.session isKindOfClass:NSURLSession.class])
    {
      self.underlyingTask = [(NSURLSession *)self.session dataTaskWithRequest:self.request
                                                            completionHandler:completion];
    }
    else
    {
      self.underlyingTask = [self.session fb_dataTaskWithRequest:self.request completionHandler:completion];
    }
    self.request = nil;
    self.session = nil;
    [self.underlyingTask fb_resume];
  }
}

- (void)fb_cancel
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    [self.underlyingTask fb_cancel];
    [self finishWithData:nil response:nil error:FBSDKTrackingConsent.cancellationError];
  }
}

- (void)finishWithData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error
{
  if (self.finished)
  {
    return;
  }
  self.finished = YES;
  void (^completion)(NSData *, NSURLResponse *, NSError *) = self.completion;
  self.completion = nil;
  self.request = nil;
  self.session = nil;
  self.underlyingTask = nil;
  [FBSDKTrackingConsent unregisterTask:self];
  if (completion)
  {
    completion(data, response, error);
  }
}

@end

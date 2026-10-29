/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKTrackingConsent.h"

#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <FBSDKCoreKit_Basics/FBSDKBasicUtility.h>
#import <FBSDKCoreKit_Basics/FBSDKNetworkTask.h>

static NSObject *consentLock;
static NSHashTable *consentTasks;
static BOOL appGranted;
static BOOL changingConsent;
static uint64_t consentGeneration;
static BOOL (^eraseCoreState)(NSError **);

@implementation FBSDKTrackingConsent

+ (void)initialize
{
  if (self == FBSDKTrackingConsent.class)
  {
    consentLock = [NSObject new];
    consentTasks = [NSHashTable weakObjectsHashTable];
    // A previous process's grant never authorizes this process or its saved identity.
    [self setEnabled:NO error:nil];
  }
}

+ (NSObject *)lock
{
  return consentLock;
}

+ (BOOL)systemAllowsTracking
{
  if (@available(iOS 14, tvOS 14, *))
  {
    return ATTrackingManager.trackingAuthorizationStatus == ATTrackingManagerAuthorizationStatusAuthorized;
  }
  // An OS without ATT cannot supply the authorization required by this distribution.
  return NO;
}

+ (BOOL)isEnabled
{
  @synchronized(consentLock)
  {
    if (appGranted && ![self systemAllowsTracking])
    {
      [self setEnabled:NO error:nil];
    }
    return appGranted;
  }
}

+ (uint64_t)generation
{
  @synchronized(consentLock)
  {
    return consentGeneration;
  }
}

+ (BOOL)isCurrentGeneration:(uint64_t)generation
{
  @synchronized(consentLock)
  {
    return self.isEnabled && consentGeneration == generation;
  }
}

+ (NSError *)cancellationError
{
  return [NSError errorWithDomain:NSURLErrorDomain
                             code:NSURLErrorCancelled
                         userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Meta request cancelled because tracking consent is unavailable or was withdrawn."
                         }];
}

+ (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error
{
  @synchronized(consentLock)
  {
    if (changingConsent)
    {
      if (enabled && error)
      {
        *error = self.cancellationError;
      }
      return !enabled;
    }
    if (enabled && appGranted && [self systemAllowsTracking])
    {
      return YES;
    }
    changingConsent = YES;
    @try
    {
      // Fence first. Cancellation callbacks cannot restore state while erasure is in progress.
      appGranted = NO;
      consentGeneration++;
      NSArray *tasks = consentTasks.allObjects;
      [consentTasks removeAllObjects];
      for (id task in tasks)
      {
        [task fb_cancel];
      }

      NSError *identityError;
      BOOL erased =
          [self eraseFileAtPath:[FBSDKBasicUtility persistenceFilePath:@"com-facebook-sdk-PersistedAnonymousID.json"]
                          error:&identityError];
      NSError *coreError;
      if (eraseCoreState && !eraseCoreState(&coreError))
      {
        erased = NO;
      }
      if (!erased)
      {
        if (error)
        {
          *error = [NSError errorWithDomain:@"com.endearing.facebook.tracking-consent"
                                    code:2
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    @"Meta tracking is disabled, but saved tracking data could not be erased. Retry withdrawal before granting again.",
                                  NSUnderlyingErrorKey: identityError ?: coreError ?: self.cancellationError
                                }];
        }
        return NO;
      }
      if (enabled && ![self systemAllowsTracking])
      {
        if (error)
        {
          *error = [NSError errorWithDomain:@"com.endearing.facebook.tracking-consent"
                                       code:1
                                   userInfo:@{
                                     NSLocalizedDescriptionKey :
                                         @"Meta tracking requires current App Tracking Transparency authorization."
                                   }];
        }
        return NO;
      }
      appGranted = enabled;
      return YES;
    }
    @finally
    {
      changingConsent = NO;
    }
  }
}

+ (void)registerErasureHandler:(BOOL (^)(NSError **))handler
{
  @synchronized(consentLock)
  {
    eraseCoreState = [handler copy];
    // Registering Core never grants consent and purges legacy state before configuration reads it.
    [self setEnabled:NO error:nil];
  }
}

+ (void)registerTask:(id)task
{
  @synchronized(consentLock)
  {
    [consentTasks addObject:task];
  }
}

+ (void)unregisterTask:(id)task
{
  @synchronized(consentLock)
  {
    [consentTasks removeObject:task];
  }
}

+ (BOOL)eraseFileAtPath:(NSString *)path error:(NSError **)error
{
  NSError *removalError;
  if ([NSFileManager.defaultManager removeItemAtPath:path error:&removalError] ||
      ([removalError.domain isEqualToString:NSCocoaErrorDomain] && removalError.code == NSFileNoSuchFileError))
  {
    return YES;
  }
  if (error)
  {
    *error = removalError;
  }
  return NO;
}

@end

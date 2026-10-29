/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import "FBSDKAppEventName+Internal.h"
#import "FBSDKEventLogging.h"

NSString *const FBSDKTimeSpentFilename = @"com-facebook-sdk-AppEventsTimeSpent.json";
static NSHashTable<FBSDKTimeSpentData *> *recorders;

@interface FBSDKTimeSpentData ()
@property (nonatomic, weak) id<FBSDKEventLogging> eventLogger;
@property (nonatomic) BOOL isCurrentlyLoaded;
@end

@implementation FBSDKTimeSpentData

+ (void)initialize
{
  if (self == FBSDKTimeSpentData.class)
  {
    recorders = [NSHashTable weakObjectsHashTable];
  }
}

- (instancetype)initWithEventLogger:(id<FBSDKEventLogging>)eventLogger
        serverConfigurationProvider:(id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
{
  if ((self = [super init])) {
    @synchronized(FBSDKTrackingConsent.lock)
    {
      _eventLogger = eventLogger;
      [recorders addObject:self];
    }
  }
  return self;
}

+ (void)eraseAllTrackingState
{
  for (FBSDKTimeSpentData *recorder in recorders.allObjects)
  {
    recorder.isCurrentlyLoaded = NO;
  }
}

// Only the explicit app-open event is supported. No source URL, session ID, duration,
// deactivation event, or asynchronous tracking-file write is collected.
- (void)setSourceApplication:(NSString *)sourceApplication openURL:(NSURL *)url
{
}
- (void)setSourceApplication:(NSString *)sourceApplication isFromAppLink:(BOOL)isFromAppLink
{
}
- (void)registerAutoResetSourceApplication
{
}

- (void)suspend
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    self.isCurrentlyLoaded = NO;
  }
}

- (void)restore:(BOOL)calledFromActivateApp
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled || !calledFromActivateApp || self.isCurrentlyLoaded)
    {
      return;
    }
    self.isCurrentlyLoaded = YES;
    [self.eventLogger logEvent:FBSDKAppEventNameActivatedApp parameters:nil];
  }
}

@end

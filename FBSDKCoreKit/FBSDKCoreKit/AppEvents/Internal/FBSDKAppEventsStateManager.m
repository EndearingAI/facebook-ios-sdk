/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import "FBSDKLogger.h"

@implementation FBSDKAppEventsStateManager

+ (FBSDKAppEventsStateManager *)shared
{
  static FBSDKAppEventsStateManager *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [FBSDKAppEventsStateManager new];
  });
  return instance;
}

- (NSString *)filePath
{
  return [FBSDKBasicUtility persistenceFilePath:@"com-facebook-sdk-AppEventsPersistedEvents.json"];
}

- (void)clearPersistedAppEventsStates
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    [FBSDKTrackingConsent eraseFileAtPath:self.filePath error:nil];
  }
}

- (void)persistAppEventsData:(FBSDKAppEventsState *)state
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (![FBSDKTrackingConsent isCurrentGeneration:state.trackingGeneration] || !state.events.count)
    {
      return;
    }
    NSMutableArray<FBSDKAppEventsState *> *states = [self.retrievePersistedAppEventsStates mutableCopy];
    [states addObject:state];
    NSError *error;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:states requiringSecureCoding:YES error:&error];
    if (!data || ![data writeToFile:self.filePath options:NSDataWritingAtomic error:&error])
    {
      [FBSDKLogger
          singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                    logEntry:@"Could not persist granted Meta app-open events; check app storage availability."];
    }
  }
}

- (NSArray<FBSDKAppEventsState *> *)retrievePersistedAppEventsStates
{
  @synchronized(FBSDKTrackingConsent.lock)
  {
    if (!FBSDKTrackingConsent.isEnabled)
    {
      return @[];
    }
    NSData *data = [NSData dataWithContentsOfFile:self.filePath];
    if (!data)
    {
      return @[];
    }
    NSSet<Class> *classes = [NSSet setWithObjects:NSArray.class, NSDictionary.class, NSString.class, NSNumber.class,
                                                  FBSDKAppEventsState.class, nil];
    NSArray<FBSDKAppEventsState *> *states = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                                 fromData:data
                                                                                    error:nil];
    [self clearPersistedAppEventsStates];
    NSMutableArray<FBSDKAppEventsState *> *current = [NSMutableArray new];
    for (FBSDKAppEventsState *state in states)
    {
      if ([FBSDKTrackingConsent isCurrentGeneration:state.trackingGeneration])
      {
        [current addObject:state];
      }
    }
    return current;
  }
}

@end

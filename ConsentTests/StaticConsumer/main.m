/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <UIKit/UIKit.h>
@import FBSDKCoreKit_Basics;
@import FBAEMKit;
@import FBSDKCoreKit;
@import FBSDKLoginKit;
@import FBSDKShareKit;
@import FBSDKGamingServicesKit;

int main(int argc, char **argv)
{
  @autoreleasepool {
    NSError *error = nil;
    [FBSDKAppEvents setTrackingEnabled:NO error:&error];
    [FBSDKApplicationDelegate.sharedInstance initializeSDK];
    return UIApplicationMain(argc, argv, nil, nil);
  }
}

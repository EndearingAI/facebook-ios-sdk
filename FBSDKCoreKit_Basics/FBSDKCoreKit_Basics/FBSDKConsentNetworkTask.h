/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit_Basics/FBSDKNetworkTask.h>
#import <FBSDKCoreKit_Basics/FBSDKURLSessionProviding.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBSDKConsentNetworkTask : NSObject <FBSDKNetworkTask>

- (instancetype)initWithRequest:(NSURLRequest *)request
                        session:(id<FBSDKURLSessionProviding>)session
                     completion:
                         (nullable void (^)(NSData *_Nullable, NSURLResponse *_Nullable, NSError *_Nullable))completion;

@end

NS_ASSUME_NONNULL_END

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Internal consent boundary shared by all source-built SDK modules. Do not use directly.
NS_SWIFT_NAME(_TrackingConsent)
@interface FBSDKTrackingConsent : NSObject

/// All collection, request starts, response application, and erasure share this recursive monitor.
@property(class, nonatomic, readonly) NSObject *lock;
@property(class, nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(class, nonatomic, readonly) uint64_t generation;

+ (BOOL)isCurrentGeneration:(uint64_t)generation;
+ (BOOL)setEnabled:(BOOL)enabled error:(NSError *_Nullable *_Nullable)error;
+ (void)registerErasureHandler:(BOOL (^)(NSError *_Nullable *_Nullable))handler;
+ (NSError *)cancellationError;

/// Tasks register before retaining request data, including tasks not yet resumed.
+ (void)registerTask:(id)task;
+ (void)unregisterTask:(id)task;
+ (BOOL)eraseFileAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// This protocol crosses the AEM/Core ObjC boundary. Declare it in a source
// header so importing Core never requires AEM's generated Swift interface.
NS_SWIFT_NAME(SKAdNetworkReporting)
@protocol FBSKAdNetworkReporting

- (BOOL)shouldCutoff;
- (BOOL)isReportingEvent:(NSString *)event NS_SWIFT_NAME(isReportingEvent(_:));
- (void)checkAndRevokeTimer;

@end

NS_ASSUME_NONNULL_END

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBAEMKit
import FBSDKCoreKit
import Foundation

// Compile the public cross-module protocol and the Swift-generated Core API in
// the same static-library consumer used to check Objective-C module imports.
final class StaticInterop: NSObject, SKAdNetworkReporting {
  func shouldCutoff() -> Bool { false }
  func isReportingEvent(_ event: String) -> Bool { false }
  func checkAndRevokeTimer() {}

  func initializeWhileDenied() {
    ApplicationDelegate.shared.initializeSDK()
  }
}

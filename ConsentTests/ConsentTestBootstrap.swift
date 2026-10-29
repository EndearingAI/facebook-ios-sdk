/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */
@testable import FBSDKCoreKit
import Foundation

@objcMembers
public final class ConsentTestBootstrap: NSObject {
  public static func initializeSDK() {
    ApplicationDelegate.shared.scheduleAfterFirstFrame = { $0() }
    ApplicationDelegate.shared.initializeSDK()
  }

  public static func initializeSDK(completion: @escaping () -> Void) {
    ApplicationDelegate.shared.initializeSDK(launchOptions: [:], completionBlock: completion)
  }

  public static func optionalCollectionEnabled() -> Bool {
    Settings.shared.isAutoLogAppEventsEnabled || Settings.shared.isSKAdNetworkReportEnabled || [
      SDKFeature.instrument, .codelessEvents, .AAM, .privacyProtection, .modelRequest,
      .skAdNetwork, .skAdNetworkV4, .AEM, .aemAutoSetup, .iapLoggingSK2, .appEventsCloudbridge,
    ].contains { _FeatureManager.shared.isEnabled($0) }
  }
}

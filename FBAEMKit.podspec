# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

# Use the --use-libraries switch when pushing or linting this podspec

Pod::Spec.new do |s|

    s.name         = 'FBAEMKit'
    s.version      = '18.1.1'
    s.summary      = 'The kernal module for Facebook AEM solution'

    s.description  = <<-DESC
                     The Facebook SDK for iOS GamingKit framework provides:
                     * campaign level conversions from re-engagement ads.
                     DESC

    s.homepage     = 'https://developers.facebook.com/docs/ios/'
    s.license      = {
      type: 'Facebook Platform License',
      text: <<-LICENSE
      Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

      You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
      copy, modify, and distribute this software in source code or binary form for use
      in connection with the web services and APIs provided by Facebook.

      As with any software that integrates with the Facebook platform, your use of
      this software is subject to the Facebook Platform Policy
      [http://developers.facebook.com/policy/]. This copyright notice shall be
      included in all copies or substantial portions of the software.

      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
      IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
      FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
      COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
      IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
      CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
      LICENSE
    }
    s.author       = 'Facebook'

    s.platform     = :ios
    s.ios.deployment_target = '13.0'

    # Maintained source distribution: never download upstream prebuilt XCFrameworks.
  s.source = { git: 'https://github.com/EndearingAI/facebook-ios-sdk.git', branch: 'codex/consent-control' }
  s.source_files = 'FBAEMKit/FBAEMKit/**/*.{h,m,mm,swift}'
  s.public_header_files = 'FBAEMKit/FBAEMKit/include/*.h'
  s.swift_version = '5.0'
  s.requires_arc = true
  s.frameworks = 'Foundation', 'UIKit'
  s.libraries = 'z', 'c++'
  s.prefix_header_contents = '#import <TargetConditionals.h>'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'ENABLE_TESTABILITY' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) FBSDKCOCOAPODS=1',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++11',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/FBAEMKit/FBAEMKit/**"'
  }
  s.resource_bundles = { 'FBAEMKit_Privacy' => ['FBAEMKit/FBAEMKit/PrivacyInfo.xcprivacy'] }
    s.dependency 'FBSDKCoreKit_Basics', "#{s.version}"
  end

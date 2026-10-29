# Endearing consent-controlled iOS attribution distribution

This maintained source fork is based on upstream 18.1.1
(`80d0ee82f6370d1bace1431a80cb80575f98ee90`). The Meta license, notices, and
copyright headers remain applicable. The pod version stays 18.1.1 for React Native
wrapper compatibility; pin the full fork commit to select this implementation.

This distribution supports Meta install and app-open attribution only. Login,
Share, and Gaming pods are source-built to keep the dependency graph consistent;
their Graph transports and automatic collection are not supported here.

## Native contract

Tracking is OFF at every process start. Before initialization, the app may set
local SDK settings, but those settings never grant tracking. After the app has
checked the user's current ATT status, explicitly grant through:

```objc
NSError *error = nil;
if (![FBSDKAppEvents setTrackingEnabled:YES error:&error]) {
  // Keep attribution disabled and handle the actionable native error.
  return;
}
[FBSDKApplicationDelegate.sharedInstance initializeSDK];
[FBSDKAppEvents.shared activateApp];
```

Actual ATT authorization is checked again at native event, anonymous-ID, IDFA,
request-start, and response boundaries. A boundary that observes OS revocation
withdraws the native grant and erases state. Foreground AppEvents observation
also checks the boundary. A later ATT authorization does not itself re-enable
the SDK; the app must make another explicit grant. An OS without the ATT API cannot
supply authorization and all tracking grants are refused there.

Withdraw synchronously with `setTrackingEnabled:NO error:&error`. The SDK first
denies and advances its consent generation, then cancels transport and timers,
settles outstanding callbacks exactly once with cancellation errors, and erases
queued events, offline archives, session/source information, user data, cached
identifiers, and the persisted anonymous ID. Queued main blocks retain mutable
containers whose payloads are cleared immediately during withdrawal. Old
callbacks and retries cannot restore or transmit them after a new grant.

If a file or preference erasure fails, the setter returns NO with an NSError.
Tracking remains denied and a grant is refused until erasure succeeds. Retry the
withdrawal after resolving the storage error. Cancellation handlers cannot grant
tracking reentrantly while withdrawal is in progress.

`FBSDKAppEvents.shared.anonymousID` is nullable while denied. After a successful
withdrawal, the next grant obtains a new anonymous identity. A successful install
keeps only scalar install-once bookkeeping, without the old identity or Graph
response payload. An in-flight/failed install has no permanent success marker.

Automatic events and server migration overrides, automatic IAP, SKAN, AEM,
codeless, metadata/model collection, crash/error diagnostics, user matching data,
push/source attribution, and extinfo are disabled. Explicit `activateApp` works
with automatic logging disabled. Graph admission permits only the activities
endpoint and install/custom-app-event categories; AppEvents admits only explicit
app-open events. No domain/configuration refresh or piggyback transport runs.
Sentry and the application retain their own diagnostics/SKAN responsibilities.

Granted offline app-open events may be retained within the current consent
generation. A new process starts denied and erases previous tracking state, so
previous-process event payloads are not replayed after a new grant.

## Source CocoaPods installation

Select **all six pods from the same complete fork commit**. Pinning Core alone can
mix upstream binary dependencies into the graph.

```ruby
meta_commit = '<full maintained fork SHA>'
%w[FBSDKCoreKit_Basics FBAEMKit FBSDKCoreKit FBSDKLoginKit FBSDKShareKit FBSDKGamingServicesKit].each do |name|
  pod name, :git => 'https://github.com/EndearingAI/facebook-ios-sdk.git', :commit => meta_commit
end
```

The podspecs compile ObjC/ObjC++/Swift sources, public headers, privacy manifests,
and SDK strings. iOS 13+, Swift 5, ARC, and C++11 are configured by the podspecs.
Release testability is enabled because upstream Core imports AEM with `@testable`.
A static Swift pod consumer needs Swift runtime linkage (the app's Swift
AppDelegate provides this; an otherwise ObjC-only host can add an empty Swift
file). No generated Xcode projects or binary artifacts are committed.

`Package.swift` still describes upstream binary releases and is deliberately
unchanged. Use the source CocoaPods distribution for this consent contract.

## Verification

Generate the Basics, AEM, and Core projects with xcodegen, then generate
`ConsentTests/project.yml`. Run the native XCTest scheme with an explicit
simulator destination:

```sh
xcodebuild test -project ConsentTests/MetaConsentTests.xcodeproj \
  -scheme MetaConsentTests -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath /tmp/meta-ios-consent-build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
```

The tests use actual source SDK modules and real NSURLSession traffic intercepted
by a recording/offline/holding NSURLProtocol. They replace only OS ATT status and
filesystem failures to exercise the native boundary. They cover denied startup,
real offline activation/withdrawal/reconnect, late/suspended requests, callback
settlement, immediate payload release, erasure errors, explicit app-open wire
payloads, fresh identity, and install-once bookkeeping.

For the upstream all-module suite, use an explicit device to avoid interfering
with another developer's simulator:

```sh
FBSDK_TEST_DESTINATION='platform=iOS Simulator,id=<UDID>' ./scripts/test.sh
```

The upstream suite assumes automatic collection and social APIs are enabled;
those expectations differ from this attribution-only distribution. Report its
result separately from the native consent contract tests and source consumer
build rather than weakening or skipping its assertions.

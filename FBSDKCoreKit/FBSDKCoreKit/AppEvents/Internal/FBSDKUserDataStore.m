/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKUserDataStore.h>

// Advanced matching and caller-supplied user identifiers are disabled in this attribution distribution.
@implementation FBSDKUserDataStore

- (void)setUserEmail:(nullable NSString *)email
           firstName:(nullable NSString *)firstName
            lastName:(nullable NSString *)lastName
               phone:(nullable NSString *)phone
         dateOfBirth:(nullable NSString *)dateOfBirth
              gender:(nullable NSString *)gender
                city:(nullable NSString *)city
               state:(nullable NSString *)state
                 zip:(nullable NSString *)zip
             country:(nullable NSString *)country
{
}

- (void)setUserEmail:(nullable NSString *)email
           firstName:(nullable NSString *)firstName
            lastName:(nullable NSString *)lastName
               phone:(nullable NSString *)phone
         dateOfBirth:(nullable NSString *)dateOfBirth
              gender:(nullable NSString *)gender
                city:(nullable NSString *)city
               state:(nullable NSString *)state
                 zip:(nullable NSString *)zip
             country:(nullable NSString *)country
          externalId:(nullable NSString *)externalId
{
}

- (void)setUserData:(NSString *)data forType:(FBSDKAppEventUserDataType)type
{
}
- (void)setHashData:(NSString *)data forType:(FBSDKAppEventUserDataType)type
{
}
- (void)setInternalHashData:(NSString *)data forType:(FBSDKAppEventUserDataType)type
{
}
- (void)setEnabledRules:(NSArray<NSString *> *)rules
{
}
- (void)clearUserDataForType:(FBSDKAppEventUserDataType)type
{
}
- (void)clearUserData
{
}
- (NSString *)getUserData
{
  return nil;
}
- (NSString *)getHashedData
{
  return nil;
}
- (NSString *)getInternalHashedDataForType:(FBSDKAppEventUserDataType)type
{
  return nil;
}
@end

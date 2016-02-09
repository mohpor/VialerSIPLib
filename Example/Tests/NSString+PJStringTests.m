//
//  NSString+PJStringTests.m
//  VialerSIPLib
//
//  Created by Bob Voorneveld on 22/01/16.
//  Copyright © 2016 Harold. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <VialerSIPLib-iOS/NSString+PJString.h>

@interface NSString_PJStringTests : XCTestCase

@end

@implementation NSString_PJStringTests

- (void)testThatPJStringCanBecomeNSString {
    pj_str_t pjString = pj_str("testing string");

    XCTAssertEqualObjects([NSString stringWithPJString:pjString], @"testing string", @"It should be possible to convert an PJString to an NSString");
}

- (void)testPrependSipToString {
    NSString *testString = @"testUri";

    XCTAssertEqualObjects(@"sip:testUri", [testString prependSipUri], @"There should be sip: prepended to the string");
}

- (void)testPreventDoubleAddingSipToString {
    NSString *testString = @"sip:testUri";

    XCTAssertEqualObjects(@"sip:testUri", [testString prependSipUri], @"There should not be sip: prepended to the string if there is sip:already");
}

- (void)testNSStringCanReturnPJString {
    NSString *testString = @"testing string";

    XCTAssertEqual(strcmp(testString.pjString.ptr, "testing string"), 0, @"The string should be converted properly");
}

- (void)testStringCanBeConvertedToSipUriWithDomain {
    NSString *testString = @"42";

    pj_str_t result = [testString sipUriWithDomain:@"proxy.test.com"];
    XCTAssertEqual(strcmp(result.ptr, "sip:42@proxy.test.com"), 0, @"String should be converted to correct pj string with sipUri format");
}

@end

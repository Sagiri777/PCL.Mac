//
//  YggdrasilClientTest.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 8/8/25.
//

import PCL_Mac
import Foundation
import Testing

@Suite(.enabled(if: pclIntegrationTestsEnabled))
struct YggdrasilClientTest {
    @Test func testLogin() async throws {
        let identifier = try #require(ProcessInfo.processInfo.environment["PCL_YGGDRASIL_TEST_IDENTIFIER"])
        let password = try #require(ProcessInfo.processInfo.environment["PCL_YGGDRASIL_TEST_PASSWORD"])
        let client = YggdrasilClient(URL(string: "https://littleskin.cn/api/yggdrasil")!)
        let response = try await client.authenticate(identifier: identifier, password: password)
        #expect(!response.profileName.isEmpty)
    }
    
    @Test func testGetProfile() async throws {
        let profileID = try #require(ProcessInfo.processInfo.environment["PCL_YGGDRASIL_TEST_PROFILE_ID"])
        let client = YggdrasilClient(URL(string: "https://littleskin.cn/api/yggdrasil")!)
        let profile = try await client.getProfile(id: profileID)
        #expect(!profile.name.isEmpty)
    }
}

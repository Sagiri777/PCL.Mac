//
//  Constants.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation

public struct SharedConstants {
    public static let shared = SharedConstants()
    
    public let applicationContentsURL: URL
    public let applicationResourcesURL: URL
    public let logURL: URL
    public let applicationSupportURL: URL = .applicationSupportDirectory.appending(path: "PCL-Mac")
    public let temperatureURL: URL
    public let authlibInjectorURL: URL
    
    public let dateFormatter = DateFormatter()
    
    public let isDevelopment: Bool
    public let version: String
    public let branch: String
    public let editionName = "PCL.Mac Liquid Glass Edition"
    public let editionSubtitle = "macOS 26 原生液态玻璃增强版"
    public let projectURL = URL(string: "https://github.com/Sagiri777/PCL.Mac")!
    
    private init() {
        self.applicationContentsURL = Bundle.main.bundleURL.appending(path: "Contents")
        self.applicationResourcesURL = self.applicationContentsURL.appending(path: "Resources")
        self.logURL = applicationSupportURL.appending(path: "Logs").appending(path: "app.log")
        self.temperatureURL = applicationSupportURL.appending(path: "Temp")
        self.authlibInjectorURL = applicationSupportURL.appending(path: "authlib-injector.jar")
        self.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.0"
        
        self.dateFormatter.dateFormat = "yyyy/MM/dd HH:mm"
        self.dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        
        let developmentValue = Bundle.main.object(forInfoDictionaryKey: "IS_DEVELOPMENT") as? String
        self.isDevelopment = developmentValue?.lowercased() != "false"
        let branchValue = Bundle.main.object(forInfoDictionaryKey: "BRANCH") as? String
        if let branchValue, !branchValue.isEmpty {
            self.branch = branchValue
        } else {
            self.branch = "本地构建"
        }
    }
}

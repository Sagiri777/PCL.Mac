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
    public let version = "0.2.0"
    public let branch: String
    public let editionName = "PCL.Mac Liquid Glass Edition"
    public let editionSubtitle = "macOS 26 原生液态玻璃增强版"
    public let projectURL = URL(string: "https://github.com/Meloong-Git/PCL")!
    
    private init() {
        self.applicationContentsURL = Bundle.main.bundleURL.appending(path: "Contents")
        self.applicationResourcesURL = self.applicationContentsURL.appending(path: "Resources")
        self.logURL = applicationSupportURL.appending(path: "Logs").appending(path: "app.log")
        self.temperatureURL = applicationSupportURL.appending(path: "Temp")
        self.authlibInjectorURL = applicationSupportURL.appending(path: "authlib-injector.jar")
        
        self.dateFormatter.dateFormat = "yyyy/MM/dd HH:mm"
        self.dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        
        self.isDevelopment = (Bundle.main.object(forInfoDictionaryKey: "IS_DEVELOPMENT") as! String) == "false" ? false : true
        let branch = Bundle.main.object(forInfoDictionaryKey: "BRANCH") as! String
        self.branch = branch.isEmpty ? "本地构建" : branch
    }
}

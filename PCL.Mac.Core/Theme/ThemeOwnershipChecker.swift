//
//  ThemeOwnershipChecker.swift
//  PCL.Mac
//
//  保留兼容 API。PCL.Mac 的所有本地主题默认可用，不再要求激活码。
//

import Foundation

public final class ThemeOwnershipChecker {
    public static let shared = ThemeOwnershipChecker()

    public var unlockedThemes: [String] = []

    public func isUnlocked(_ theme: ThemeInfo) -> Bool { true }

    private init() {}
}

//
//  OptionalExtension.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/19.
//

import Foundation

public extension Optional {
    func unwrap(_ errorMessage: String? = nil, file: String = #file, line: Int = #line) throws -> Wrapped {
        guard let value = self else {
            let source = file.split(separator: "/").last.map(String.init) ?? file
            throw MyLocalizedError(reason: errorMessage ?? "\(source):\(line) 解包失败")
        }
        return value
    }
}

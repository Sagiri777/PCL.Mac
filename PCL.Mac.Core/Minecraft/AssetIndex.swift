//
//  AssetIndex.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/15.
//

import SwiftyJSON
import Foundation

public class AssetIndex {
    public let objects: [Object]
    
    public init(_ json: JSON) {
        self.objects = json["objects"].dictionaryValue.values.compactMap(Object.init)
    }
    
    public init(objects: [Object]) {
        self.objects = objects
    }
    
    public class Object {
        public let hash: String
        public let size: Int32
        
        public init?(_ json: JSON) {
            let hash = json["hash"].stringValue.lowercased()
            guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { return nil }
            let size = json["size"].int32Value
            guard size >= 0 else { return nil }
            self.hash = hash
            self.size = size
        }
        
        public func appendTo(_ url: URL) -> URL {
            return url.appending(path: String(hash.prefix(2))).appending(path: hash)
        }
    }
    
    public static func parse(_ data: Data) throws -> AssetIndex {
        let json = try JSON(data: data)
        guard let objectDictionary = json["objects"].dictionary else {
            throw MyLocalizedError(reason: "资源索引缺少 objects 字段")
        }
        let index = AssetIndex(json)
        guard index.objects.count == objectDictionary.count else {
            throw MyLocalizedError(reason: "资源索引包含无效的资源哈希")
        }
        return index
    }
}

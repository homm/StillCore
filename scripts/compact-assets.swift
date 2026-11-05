import Foundation

let path = URL(fileURLWithPath: CommandLine.arguments[1])
var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
let renditions = manifest["renditions"] as! [[String: Any]]
var retained = renditions.filter { rendition in
    let name = rendition["name"] as! String
    let content = rendition["content"] as! [String: Any]
    let isSizeTable = name == "AppIcon" && content["type"] as? String == "multisize"
    let isFlattenedIcon = name.hasPrefix("AppIcon") && name.contains("NSAppearance")
    return !isSizeTable && !isFlattenedIcon
}
let linkedKeys = retained.compactMap { rendition -> NSDictionary? in
    let content = rendition["content"] as! [String: Any]
    return content["target"] as? NSDictionary
}
retained.removeAll { rendition in
    if rendition["layout"] as? Int == 1004 {
        let key = rendition["key"] as! NSDictionary
        return !linkedKeys.contains(key)
    }
    return false
}
manifest["renditions"] = retained
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try data.write(to: path)

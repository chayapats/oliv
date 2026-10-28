import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: collect_rust_licenses.swift metadata.json output-directory") }
let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let destination = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var index = "# Rust dependency notices\n\n"
for package in object["packages"] as! [[String: Any]] {
    let name = package["name"] as! String, version = package["version"] as! String
    let source = URL(fileURLWithPath: package["manifest_path"] as! String).deletingLastPathComponent()
    index += "- \(name) \(version): \(package["license"] as? String ?? "see supplied license")\n"
    for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey]) {
        let filename = file.lastPathComponent.uppercased()
        guard ["LICENSE", "LICENCE", "COPYING", "NOTICE"].contains(where: { filename.hasPrefix($0) }),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let target = destination.appendingPathComponent("\(name)-\(version)-\(file.lastPathComponent)")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: file, to: target)
    }
}
try index.write(to: destination.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)

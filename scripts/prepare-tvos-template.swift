import Foundation

// Derive the tvOS project from the current iOS template instead of copying it.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/prepare-tvos-template.swift /path/to/template")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let project = root.appendingPathComponent("__PROJECT_NAME__.xcodeproj/project.pbxproj")
var format = PropertyListSerialization.PropertyListFormat.openStep
var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: project), options: [], format: &format) as! [String: Any]
var objects = plist["objects"] as! [String: [String: Any]]
var hasRuntimePackage = false
for (id, var object) in objects {
    if object["isa"] as? String == "XCBuildConfiguration", var settings = object["buildSettings"] as? [String: Any] {
        if settings.removeValue(forKey: "IPHONEOS_DEPLOYMENT_TARGET") != nil { settings["TVOS_DEPLOYMENT_TARGET"] = "13.0" }
        if settings["SDKROOT"] != nil { settings["SDKROOT"] = "appletvos" }
        settings["TARGETED_DEVICE_FAMILY"] = "3"
        settings["SUPPORTED_PLATFORMS"] = "appletvos appletvsimulator"
        settings["SUPPORTS_MACCATALYST"] = "NO"
        object["buildSettings"] = settings
    }
    if object["isa"] as? String == "XCRemoteSwiftPackageReference", (object["repositoryURL"] as? String)?.contains("NativeScript/ios-spm") == true {
        hasRuntimePackage = true
        object = ["isa": "XCLocalSwiftPackageReference", "relativePath": "internal/local-spm"]
    }
    if object["isa"] as? String == "XCLocalSwiftPackageReference", object["relativePath"] as? String == "internal/local-spm" {
        hasRuntimePackage = true
    }
    objects[id] = object
}
guard hasRuntimePackage else { fatalError("The iOS template no longer contains the expected runtime package reference.") }
plist["objects"] = objects
// Xcode reads XML projects, but the CLI's project parser requires OpenStep.
func labelFor(_ id: String) -> String {
    guard let object = objects[id] else { return id }
    if let name = object["name"] as? String { return name }
    if let path = object["path"] as? String { return (path as NSString).lastPathComponent }
    let isa = object["isa"] as? String ?? id
    let phaseNames = ["PBXFrameworksBuildPhase": "Frameworks", "PBXSourcesBuildPhase": "Sources", "PBXResourcesBuildPhase": "Resources", "PBXShellScriptBuildPhase": "Run Script", "PBXCopyFilesBuildPhase": "CopyFiles"]
    if let name = phaseNames[isa] { return name }
    if isa == "PBXBuildFile", let ref = object["fileRef"] as? String {
        let phase = objects.first { ($0.value["files"] as? [String])?.contains(id) == true }
        return labelFor(ref) + (phase.map { " in " + labelFor($0.key) } ?? "")
    }
    return isa
}
func openStep(_ value: Any, _ depth: Int = 0) throws -> String {
    let indent = String(repeating: "\t", count: depth)
    if let dictionary = value as? [String: Any] {
        let entries = try dictionary.keys.sorted().map { key in
            let serialized = key == "objects" ? try openStepObjects() : try openStep(dictionary[key]!, depth + 1)
            return "\(indent)\t\(try openStep(key)) = \(serialized);"
        }
        return "{\n" + entries.joined(separator: "\n") + "\n\(indent)}"
    }
    if let array = value as? [Any] {
        let entries = try array.map { "\(indent)\t\(try openStep($0, depth + 1))," }
        return "(\n" + entries.joined(separator: "\n") + "\n\(indent))"
    }
    let string = String(describing: value)
    if string.range(of: "^[A-Za-z0-9_./]+$", options: .regularExpression) != nil {
        if objects[string] != nil {
            let label = labelFor(string).replacingOccurrences(of: "*/", with: "* /")
            return string + " /* " + label + " */"
        }
        return string
    }
    let data = try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8)!
}
func openStepObjects() throws -> String {
    let groups = Dictionary(grouping: objects.keys) { objects[$0]!["isa"] as! String }
    var result = "{\n"
    for group in groups.keys.sorted() {
        result += "/* Begin \(group) section */\n"
        for id in groups[group]!.sorted() {
            result += "\t\t\(try openStep(id)) = \(try openStep(objects[id]!, 2));\n"
        }
        result += "/* End \(group) section */\n"
    }
    return result + "\t}"
}
try ("// !$*UTF8*$!\n" + openStep(plist) + "\n").write(to: project, atomically: true, encoding: .utf8)
let config = root.appendingPathComponent("internal/nativescript-build.xcconfig")
var text = try String(contentsOf: config, encoding: .utf8)
text = text.replacingOccurrences(of: "TARGETED_DEVICE_FAMILY = 1,2", with: "TARGETED_DEVICE_FAMILY = 3")
if !text.contains("EXCLUDED_ARCHS[sdk=appletvsimulator*]") {
text += "\nEXCLUDED_ARCHS[sdk=appletvsimulator*] = x86_64 i386\nEXCLUDED_ARCHS[sdk=appletvos*] = x86_64 i386\n"
}
try text.write(to: config, atomically: true, encoding: .utf8)

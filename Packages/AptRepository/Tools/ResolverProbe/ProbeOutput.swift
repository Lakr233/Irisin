import IrisinProtocol

struct ProbeOutput: Encodable {
    var install: [String: String]
    var remove: [String]
    var final: [String: String]
    var heldBack: [String]
    var stages: [InstallerStage]
    var seconds: Double
}

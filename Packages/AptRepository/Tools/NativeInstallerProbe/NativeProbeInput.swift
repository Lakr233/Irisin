import Foundation
import IrisinProtocol

struct NativeProbeInput: Decodable {
    let root: String
    let database: String
    let archives: [String: String]
    let remove: [String]
    let stages: [InstallerStage]
}

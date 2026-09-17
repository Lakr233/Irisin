import WCDBSwift

extension ResolutionRevisionRow {
    enum CodingKeys: String, CodingTableKey {
        typealias Root = ResolutionRevisionRow
        case id, revision
        nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindColumnConstraint(id, isPrimary: true)
        }
    }
}

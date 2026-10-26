/// What answers the page: the app on iOS, the launcher on tvOS. The server
/// opens every sealed call and stream before asking, so a responder sees
/// only what the key's holder sent.
public protocol WebResponder: Sendable {
    /// One call's answer: `op` and its `args` as the page sent them.
    func answer(_ op: String, _ args: JSONValue) async -> WebAnswer

    /// An operation's lines after `after`, each handed to `send` as it comes.
    /// Returns when the operation has ended, or when `send` answers false:
    /// the page has gone.
    func stream(after: Int, send: @escaping @Sendable (JSONValue) async -> Bool) async
}

public enum WebAnswer: Sendable, Equatable {
    case result(JSONValue)
    /// Said to the page as it is, in the device's language.
    case failure(String)
}

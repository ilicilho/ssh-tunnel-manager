import Foundation
import Security

/// Stores each tunnel's SSH password in the macOS login Keychain, keyed by the
/// tunnel's UUID. The Keychain encrypts the secret at rest with the user's
/// login credentials; nothing sensitive is ever written to tunnels.json.
///
/// The UI is deliberately write-only: it can check that a password exists,
/// replace it, or delete it, but never reads the value back for display. The
/// only reader is `AskpassHelper`, which hands it to ssh at connect time.
enum PasswordStore {
    /// A fixed service name (not derived from the bundle at runtime) so the app
    /// and its askpass re-invocation always address the same items.
    static let service = "io.github.0fuz.SSHTunnelManager.ssh-password"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "Keychain error: \(detail)")
        }
    }

    private static func baseQuery(for tunnelID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tunnelID.uuidString
        ]
    }

    /// Whether a password is saved for the tunnel. Asks only for attributes, so
    /// it never decrypts the secret and never triggers a Keychain prompt.
    static func exists(for tunnelID: UUID) -> Bool {
        var query = baseQuery(for: tunnelID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Save or replace the tunnel's password.
    static func save(_ password: String, for tunnelID: UUID, label: String) throws {
        let data = Data(password.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "SSH Tunnel Manager: \(label)"
        ]
        var status = SecItemUpdate(baseQuery(for: tunnelID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery(for: tunnelID)
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(for tunnelID: UUID) {
        SecItemDelete(baseQuery(for: tunnelID) as CFDictionary)
    }

    /// Copy one tunnel's password to another (used when cloning a tunnel).
    static func copy(from sourceID: UUID, to destinationID: UUID, label: String) {
        guard let password = read(for: sourceID) else { return }
        try? save(password, for: destinationID, label: label)
    }

    /// Decrypts and returns the password. Only for handing it to ssh — never
    /// call this to populate UI.
    fileprivate static func read(for tunnelID: UUID) -> String? {
        var query = baseQuery(for: tunnelID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// ssh can't be given a password on its command line, and the GUI has no TTY
/// for it to prompt on. Instead ssh is pointed (SSH_ASKPASS) back at this very
/// executable, which — when it sees `tunnelIDKey` in its environment — acts as
/// a tiny askpass program: print the tunnel's password and exit, without ever
/// starting the app. The password therefore never appears in argv, in a file,
/// or in the environment; it only crosses the pipe ssh opened to read it.
enum AskpassHelper {
    static let tunnelIDKey = "STM_ASKPASS_TUNNEL_ID"

    /// Environment that makes ssh ask this executable for the tunnel's password.
    static func environment(for tunnelID: UUID) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        // "force": use askpass even though there's no DISPLAY and regardless of
        // a TTY (OpenSSH 8.4+, which every macOS this app supports ships).
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env[tunnelIDKey] = tunnelID.uuidString
        return env
    }

    /// Call first thing in `main`. Returns normally when this is a regular app
    /// launch; otherwise answers ssh's prompt and exits.
    static func runIfInvoked() {
        let env = ProcessInfo.processInfo.environment
        guard let idString = env[tunnelIDKey] else { return }

        // Answer only genuine password prompts. ssh also routes host-key
        // confirmations ("confirm") and notices ("none") through askpass —
        // declining those keeps the old BatchMode behavior of failing visibly
        // on an unknown/changed host key instead of silently trusting it. Key
        // passphrase prompts are declined too: this is not that secret.
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        // The host-key question isn't always tagged "confirm", so it's also
        // recognised by its wording — answering it with anything but yes/no
        // makes ssh re-ask forever.
        let isHostKeyQuestion = prompt.contains("yes/no") || prompt.contains("fingerprint")
        guard env["SSH_ASKPASS_PROMPT"] == nil,
              !isHostKeyQuestion,
              prompt.contains("password"),
              let id = UUID(uuidString: idString),
              let password = PasswordStore.read(for: id) else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        exit(0)
    }
}

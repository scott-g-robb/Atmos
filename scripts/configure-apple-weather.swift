// Compile with Sources/Atmos/Weather/WeatherKitCredentials.swift. Never copies credentials into build products.
import Foundation
import Security

@main enum ConfigureAppleWeather {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 6 else {
      print("Usage: configure-apple-weather KEY_FILE KEY_ID TEAM_ID SERVICE_ID ATMOS_APP")
      exit(2)
    }
    let credentials = WeatherKitCredentials(
      teamID: args[3], keyID: args[2], serviceID: args[4],
      privateKeyPEM: try String(contentsOfFile: args[1], encoding: .utf8))
    _ = try credentials.token()  // Validate the key before changing the Keychain.
    var trusted: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(args[5], &trusted) == errSecSuccess, let trusted
    else { throw CocoaError(.fileReadNoPermission) }
    var access: SecAccess?
    guard
      SecAccessCreate("Atmos Apple Weather" as CFString, [trusted] as CFArray, &access)
        == errSecSuccess, let access
    else { throw CocoaError(.fileReadNoPermission) }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: WeatherKitCredentials.service,
      kSecAttrAccount as String: "personal-weather",
    ]
    let data = try JSONEncoder().encode(credentials)
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrLabel as String] = "Atmos · Apple Weather"
    attributes[kSecAttrAccess as String] = access
    let result = SecItemAdd(attributes as CFDictionary, nil)
    if result == errSecDuplicateItem {
      let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccess as String: access]
      guard SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess else {
        throw CocoaError(.fileWriteNoPermission)
      }
    } else if result != errSecSuccess {
      throw CocoaError(.fileWriteNoPermission)
    }
    print(
      "Apple Weather configured in this Mac's Keychain. No private key was added to the app or installer."
    )
  }
}

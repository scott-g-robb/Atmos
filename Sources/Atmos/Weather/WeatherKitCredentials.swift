import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Personal WeatherKit REST credentials live in this Mac's Keychain, never in the app bundle.
struct WeatherKitCredentials: Codable {
  let teamID: String
  let keyID: String
  let serviceID: String
  let privateKeyPEM: String
  static let service = "dev.grobb.Atmos.weatherkit"

  func token(at date: Date = Date()) throws -> String {
    func base64(_ data: Data) -> String {
      data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
        of: "/", with: "_"
      ).replacingOccurrences(of: "=", with: "")
    }
    let header = try JSONSerialization.data(
      withJSONObject: ["alg": "ES256", "kid": keyID, "id": "\(teamID).\(serviceID)"],
      options: .sortedKeys)
    let now = Int(date.timeIntervalSince1970)
    let claims = try JSONSerialization.data(
      withJSONObject: ["iss": teamID, "iat": now - 30, "exp": now + 600, "sub": serviceID],
      options: .sortedKeys)
    let message = "\(base64(header)).\(base64(claims))"
    let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    let signature = try key.signature(for: Data(message.utf8))
    return "\(message).\(base64(signature.rawRepresentation))"
  }

  static var exists: Bool {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "personal-weather",
      kSecUseAuthenticationContext as String: context,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  static func load() -> WeatherKitCredentials? {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "personal-weather", kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

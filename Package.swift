// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Aeolian",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Aeolian", targets: ["Aeolian"])],
  targets: [
    .target(name: "CWeatherCore", path: "Sources/CWeatherCore", publicHeadersPath: "include"),
    .executableTarget(
      name: "Aeolian",
      dependencies: ["CWeatherCore"],
      path: "Sources/Aeolian",
      linkerSettings: [
        .unsafeFlags([
          "-L", Context.packageDirectory + "/.build/weather-core", "-laeolian_weather_core",
        ])
      ]
    ),
    .testTarget(name: "AeolianTests", dependencies: ["Aeolian"]),
  ]
)

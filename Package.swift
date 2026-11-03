// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Atmos",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "CWeatherCore", path: "Sources/CWeatherCore", publicHeadersPath: "include"),
    .executableTarget(
      name: "Atmos",
      dependencies: ["CWeatherCore"],
      path: "Sources/Atmos",
      linkerSettings: [
        .unsafeFlags([
          "-L", Context.packageDirectory + "/.build/weather-core", "-latmos_weather_core",
        ])
      ]
    ),
    .testTarget(name: "AtmosTests", dependencies: ["Atmos"]),
  ]
)

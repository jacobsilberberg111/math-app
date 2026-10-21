// swift-tools-version: 5.9

// An iPad app package: open TutorNotes.swiftpm in Swift Playgrounds (iPad or Mac) or in Xcode.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Tutor Notes",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Tutor Notes",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.tutornotes",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .microphone(purposeString: "Record lectures alongside your notes and ask your tutor questions by voice."),
                .speechRecognition(purposeString: "Turn what you say into questions for your tutor."),
                .camera(purposeString: "Scan worksheets, past papers and mark schemes into your notes.")
            ],
            appCategory: .education
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)

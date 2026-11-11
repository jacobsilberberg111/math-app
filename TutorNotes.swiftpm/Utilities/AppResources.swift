import Foundation

/// Files bundled from Resources/. Swift Playgrounds builds the package (resources in
/// Bundle.module); CI builds an Xcode project from project.yml (resources in the main bundle,
/// flattened). Look in both, at the top level and in subfolders.
enum AppResources {
    static func url(_ name: String, ext: String, subdirectory: String? = nil) -> URL? {
        for bundle in bundles {
            if let u = bundle.url(forResource: name, withExtension: ext) { return u }
            for dir in [subdirectory, subdirectory.map { "Resources/\($0)" }, "Resources"].compactMap({ $0 }) {
                if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: dir) { return u }
            }
        }
        return nil
    }

    private static var bundles: [Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.module, Bundle.main]
        #else
        return [Bundle.main]
        #endif
    }
}

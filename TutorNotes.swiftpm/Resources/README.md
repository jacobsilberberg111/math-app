# Bundled data

Files here ship inside the app (Package.swift `resources: [.process("Resources")]`; project.yml
lists this folder too). Load them with `AppResources.url(_:ext:)`.

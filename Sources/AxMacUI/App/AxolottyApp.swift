import AppKit

/// Entry point shared by the dev executable and the app bundle.
public enum AxolottyApp {
    @MainActor
    public static func run() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            do { try AppIcon.writeIconset(to: URL(filePath: args[i + 1])) } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

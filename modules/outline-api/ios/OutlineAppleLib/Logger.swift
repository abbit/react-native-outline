import OSLog

/// logs related to the Outline API
@available(iOSApplicationExtension 14.0, *)
let outlineLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "outlinelib")

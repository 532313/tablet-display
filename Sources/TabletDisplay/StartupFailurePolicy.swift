import Foundation

/// Startup failures that the app can recover from without being relaunched:
/// the panel stays open so the user can grant permission, free a port or retry
/// capture. Invalid CLI usage and unexpected failures still terminate.
enum StartupFailurePolicy {
    static func isRecoverable(_ error: Error) -> Bool {
        if let cliError = error as? CLIError {
            switch cliError {
            case .screenRecording, .virtualDisplay:
                return true
            case .invalid:
                return false
            }
        }
        return error is CaptureError || error is ServerError
    }
}

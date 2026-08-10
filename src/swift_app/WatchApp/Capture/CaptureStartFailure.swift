/// The few failures that can prevent a recording from starting.
///
/// This is deliberately a compact, actionable vocabulary rather than a raw
/// AVFoundation error. The Watch is the moment to tell someone what to fix;
/// detailed OS errors remain in the unified log for later diagnosis.
enum CaptureStartFailure: Equatable {
    case microphoneBusy
    case storageUnavailable
    case recorderUnavailable

    var notice: String {
        switch self {
        case .microphoneBusy: "MIC BUSY"
        case .storageUnavailable: "STORAGE FULL"
        case .recorderUnavailable: "TRY AGAIN"
        }
    }
}

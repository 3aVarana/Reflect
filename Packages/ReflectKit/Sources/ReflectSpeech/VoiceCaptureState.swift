import Speech

/// Lifecycle of a voice-capture session. The SpeechAnalyzer pipeline that
/// drives it is implemented in a later phase; the state machine is defined
/// up front so features can be built against it.
public enum VoiceCaptureState: Equatable, Sendable {
    case idle
    case preparingAssets
    case listening
    case finishing
    case failed(String)
}

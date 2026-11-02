import IntonateDSP

/// Where samples come from. The analysis side sees only the ring, so microphone and demo voice are
/// interchangeable from there on.
protocol AudioInput: AnyObject {
    var sampleRate: Double { get }
    func start(writingTo ring: SampleRing) throws
    func stop()
    /// Plays a reference pitch, or stops it for nil. Inputs without an audio route ignore this.
    func setReferenceTone(_ frequency: Double?)
}

extension AudioInput {
    func setReferenceTone(_ frequency: Double?) {}
}

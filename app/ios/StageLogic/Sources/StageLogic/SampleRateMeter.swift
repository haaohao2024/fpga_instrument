import Foundation

/// Turns the FPGA frame counter into a measured synthesis sample rate.
///
/// Every hardware-stats result carries the 32-bit `frame` counter, which the
/// FPGA increments once per finished synthesis frame — that is, once per output
/// audio sample. Pairing the counter with the phone's monotonic clock gives
/// Δframe ÷ Δtime, so the number comes from the board itself instead of
/// repeating a label.
///
/// Bluetooth notifications arrive with tens of milliseconds of jitter, so the
/// window is at least five seconds wide and slides forward one sample at a time.
public struct SampleRateMeter {
    /// One measurement: the rate plus what it was measured over.
    public struct Reading: Equatable {
        public let hertz: Double
        public let windowSeconds: Double
        public let samples: Int
    }

    /// A shorter window would make the reading jump around.
    public static let minimumWindowNanos: UInt64 = 5_000_000_000
    public static let minimumHertz: Double = 1_000
    public static let maximumHertz: Double = 1_000_000

    /// A counter step larger than half the range means the FPGA restarted, not
    /// that it wrapped: a real wrap is a tiny step (about 9.3 h at 128 kHz),
    /// while 2³¹ frames is already 4.6 h.
    private static let resetStep: UInt32 = 0x8000_0000

    public private(set) var reading: Reading?

    private var frames: [UInt32] = []
    private var times: [UInt64] = []
    private let windowNanos: UInt64

    public init(windowNanos: UInt64 = SampleRateMeter.minimumWindowNanos) {
        self.windowNanos = windowNanos
    }

    /// Forgets every sample; the next reading needs a fresh five-second window.
    public mutating func reset() {
        frames.removeAll()
        times.removeAll()
        reading = nil
    }

    /// Feeds one stats sample. `timeNanos` must come from a monotonic clock
    /// (`DispatchTime.now().uptimeNanoseconds`), never from the wall clock,
    /// which the system can step while we measure.
    ///
    /// - Returns: the new reading, or `nil` while the window is still too short
    ///   or the sample had to be discarded.
    @discardableResult
    public mutating func add(frame: UInt32, timeNanos: UInt64) -> Reading? {
        guard let lastFrame = frames.last, let lastTime = times.last else {
            frames = [frame]
            times = [timeNanos]
            return nil
        }
        // A zero or negative gap carries no information; drop the sample instead
        // of dividing by zero.
        guard timeNanos > lastTime else { return nil }
        // Wrapping subtraction keeps a genuine 32-bit rollover continuous.
        if frame &- lastFrame > SampleRateMeter.resetStep {
            reset()
            frames = [frame]
            times = [timeNanos]
            return nil
        }
        frames.append(frame)
        times.append(timeNanos)
        // Drop the oldest sample while the next one is still outside the window,
        // so the measured span is never shorter than requested.
        let cutoff = timeNanos > windowNanos ? timeNanos - windowNanos : 0
        while frames.count > 2, times[1] <= cutoff {
            frames.removeFirst()
            times.removeFirst()
        }
        let elapsed = timeNanos &- times[0]
        guard elapsed >= windowNanos, frames.count >= 2 else {
            reading = nil
            return nil
        }
        let delta = frames[frames.count - 1] &- frames[0]
        let hertz = Double(delta) / (Double(elapsed) / 1_000_000_000)
        guard hertz >= SampleRateMeter.minimumHertz, hertz <= SampleRateMeter.maximumHertz else {
            // Not a real audio rate: the history is suspect, start over.
            reset()
            return nil
        }
        let new = Reading(hertz: hertz,
                          windowSeconds: Double(elapsed) / 1_000_000_000,
                          samples: frames.count)
        reading = new
        return new
    }
}

extension SampleRateMeter.Reading {
    /// `128.0` for a 128 kHz board.
    public var kilohertz: Double { hertz / 1_000 }

    /// The line shown on the test page.
    public var summary: String {
        String(format: "实测合成采样率：%.1f kHz（±1%%，%.0f 秒平均）", kilohertz, windowSeconds)
    }

    /// Why the number can be trusted; shown as small print under the line.
    public static let provenance = "由 FPGA 帧计数与手机时钟测得，非标注值"
}

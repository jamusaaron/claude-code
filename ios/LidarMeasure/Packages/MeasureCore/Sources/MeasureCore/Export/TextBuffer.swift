import Foundation

/// Fast ASCII builder for large text exports (OBJ, USDA).
///
/// A 200k-vertex scan is ~1.5 million numbers; formatting each through `String(format:)` or
/// string interpolation takes seconds on a phone, so numbers are written digit by digit into a
/// byte buffer in fixed-point with trailing zeros trimmed.
struct TextBuffer {
    private(set) var bytes: [UInt8] = []

    init(reserving capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    var data: Data { Data(bytes) }

    mutating func append(_ s: String) {
        bytes.append(contentsOf: s.utf8)
    }

    mutating func append(byte: UInt8) {
        bytes.append(byte)
    }

    mutating func append(_ v: Int) {
        if v < 0 { bytes.append(UInt8(ascii: "-")) }
        appendDigits(UInt64(v.magnitude))
    }

    mutating func append(_ v: UInt32) {
        appendDigits(UInt64(v))
    }

    private static let powers: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000]

    /// Fixed-point with `decimals` places, trailing zeros removed ("0.5", "-1.25", "3").
    mutating func append(_ value: Float, decimals: Int) {
        append(Double(value), decimals: decimals)
    }

    mutating func append(_ value: Double, decimals: Int) {
        let d = max(0, min(decimals, Self.powers.count - 1))
        let x = value.isFinite ? value : 0
        let scale = Self.powers[d]
        let scaled = (abs(x) * scale).rounded()
        guard scaled < 9e15 else {
            append(String(describing: x))
            return
        }
        let n = UInt64(scaled)
        if x < 0 && n != 0 { bytes.append(UInt8(ascii: "-")) }
        let unit = UInt64(scale)
        appendDigits(n / unit)
        var fraction = n % unit
        guard d > 0, fraction != 0 else { return }
        var digits = d
        while fraction % 10 == 0 { fraction /= 10; digits -= 1 }
        bytes.append(UInt8(ascii: "."))
        // Leading zeros of the fraction.
        var width = 1
        var probe = fraction
        while probe >= 10 { probe /= 10; width += 1 }
        for _ in 0..<(digits - width) { bytes.append(UInt8(ascii: "0")) }
        appendDigits(fraction)
    }

    private mutating func appendDigits(_ value: UInt64) {
        if value == 0 {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        var v = value
        var tmp: [UInt8] = []
        tmp.reserveCapacity(20)
        while v > 0 {
            tmp.append(UInt8(ascii: "0") + UInt8(v % 10))
            v /= 10
        }
        bytes.append(contentsOf: tmp.reversed())
    }
}

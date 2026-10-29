import XCTest
@testable import MeasureCore

final class AccuracyTests: XCTestCase {
    func testPointSigmaGrowsWithRangeAndLowConfidence() {
        let near = AccuracyModel.pointSigma(range: 0.5, confidence: .high, snap: .mesh, tracking: .normal)
        let far = AccuracyModel.pointSigma(range: 3, confidence: .high, snap: .mesh, tracking: .normal)
        let lowConf = AccuracyModel.pointSigma(range: 0.5, confidence: .low, snap: .mesh, tracking: .normal)
        let limited = AccuracyModel.pointSigma(range: 0.5, confidence: .high, snap: .mesh, tracking: .limited)
        XCTAssertLessThan(near, far)
        XCTAssertLessThan(near, lowConf)
        XCTAssertLessThan(near, limited)
        XCTAssertEqual(near, 0.0055, accuracy: 1e-9) // 3 mm + 5 mm/m × 0.5 m
    }

    func testPlaneSnapIsMoreConfidentThanDepthPixel() {
        let plane = AccuracyModel.pointSigma(range: 1, confidence: .high, snap: .plane, tracking: .normal)
        let depth = AccuracyModel.pointSigma(range: 1, confidence: .high, snap: .depth, tracking: .normal)
        XCTAssertLessThan(plane, depth)
    }

    func testDistanceSigmaCombinesEndpointsAndDrift() {
        let s = AccuracyModel.distanceSigma(0.003, 0.004, length: 0)
        XCTAssertEqual(s, 0.005, accuracy: 1e-12)
        let long = AccuracyModel.distanceSigma(0, 0, length: 10)
        XCTAssertEqual(long, 0.05, accuracy: 1e-12)
    }

    func testSquareAreaSigmaMatchesAnalytic() {
        // Unit square, each vertex sigma s: each chord (diagonal) is sqrt(2), so
        // var = 4 × (0.5 × sqrt(2) × s)² = 2 s²  (plus drift term).
        let s = 0.01
        let pts = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)]
        let sigma = AccuracyModel.polygonAreaSigma(points: pts, sigmas: Array(repeating: s, count: 4), area: 1)
        let drift = 2 * AccuracyModel.relativeDrift
        XCTAssertEqual(sigma, (2 * s * s + drift * drift).squareRoot(), accuracy: 1e-12)
    }

    func testGrades() {
        XCTAssertEqual(AccuracyModel.grade(lengthSigma: 0.005, length: 1), .high)
        XCTAssertEqual(AccuracyModel.grade(lengthSigma: 0.005, length: 0.04), .low, "±5 mm on 4 cm is 12%")
        XCTAssertEqual(AccuracyModel.grade(lengthSigma: 0.02, length: 1), .medium)
        XCTAssertEqual(AccuracyModel.grade(lengthSigma: 0.08, length: 1), .low)
    }

    func testCalculatorDistanceAndVolume() throws {
        let a = MeasuredPoint(position: Vec3(0, 0, 0), sigma: 0.004)
        let b = MeasuredPoint(position: Vec3(0, 0, 1.5), sigma: 0.004)
        let d = MeasurementCalculator.distance(a, b)
        XCTAssertEqual(d.value, 1.5, accuracy: 1e-12)
        XCTAssertGreaterThan(d.sigma, 0.0056)

        let base = [Vec3(0, 0, 0), Vec3(4, 0, 0), Vec3(4, 0, 3), Vec3(0, 0, 3)].map { MeasuredPoint(position: $0, sigma: 0.01) }
        let room = try XCTUnwrap(MeasurementCalculator.prismVolume(base: base, top: MeasuredPoint(position: Vec3(2, 2.4, 1), sigma: 0.015)))
        XCTAssertEqual(room.value, 4 * 3 * 2.4, accuracy: 1e-9)
        XCTAssertEqual(room.height ?? 0, 2.4, accuracy: 1e-12)
        XCTAssertEqual(room.area ?? 0, 12, accuracy: 1e-12)
        XCTAssertEqual(room.segments.count, 4)
        XCTAssertGreaterThan(room.sigma, 0)
    }
}

final class FormatterTests: XCTestCase {
    let locale = Locale(identifier: "en_AU")

    func testAutoUnits() {
        let f = MetricFormatter(preference: .auto, honestPrecision: false, locale: locale)
        XCTAssertEqual(f.formatLength(0.087), "87 mm")
        XCTAssertEqual(f.formatLength(0.543), "54.3 cm")
        XCTAssertEqual(f.formatLength(1.2434), "1.243 m")
        XCTAssertEqual(f.formatArea(0.5), "5,000.0 cm²")
        XCTAssertEqual(f.formatArea(12.346), "12.35 m²")
        XCTAssertEqual(f.formatVolume(0.0005), "500 cm³")
        XCTAssertEqual(f.formatVolume(0.25), "250.0 L")
        XCTAssertEqual(f.formatVolume(28.8), "28.800 m³")
    }

    func testFixedUnits() {
        let mm = MetricFormatter(preference: .millimetres, honestPrecision: false, locale: locale)
        XCTAssertEqual(mm.formatLength(1.2434), "1,243 mm")
        let m = MetricFormatter(preference: .metres, honestPrecision: false, locale: locale)
        XCTAssertEqual(m.formatLength(0.0123), "0.012 m")
        XCTAssertEqual(m.formatVolume(0.0005), "0.001 m³")
    }

    func testHonestPrecisionDropsUncertainDigits() {
        let f = MetricFormatter(preference: .auto, honestPrecision: true, locale: locale)
        XCTAssertEqual(f.formatLength(1.2434, uncertainty: 0.006), "1.243 m")
        XCTAssertEqual(f.formatLength(1.2434, uncertainty: 0.025), "1.24 m")
        XCTAssertEqual(f.formatLength(1.2434, uncertainty: 0.15), "1.2 m")
        XCTAssertEqual(f.formatLength(0.5434, uncertainty: 0.025), "54 cm")
    }

    func testUncertaintyFormatting() {
        let f = MetricFormatter(locale: locale)
        XCTAssertEqual(f.formatLengthUncertainty(0.0042), "±4 mm")
        XCTAssertEqual(f.formatLengthUncertainty(0.0004), "±1 mm")
        XCTAssertEqual(f.formatLengthUncertainty(0.025), "±2.5 cm")
        XCTAssertEqual(f.formatAreaUncertainty(0.12, forValue: 12), "±0.12 m²")
    }

    func testUnitCycle() {
        XCTAssertEqual(LengthUnitPreference.auto.next, .millimetres)
        XCTAssertEqual(LengthUnitPreference.metres.next, .auto)
    }
}

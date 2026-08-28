import Testing
import Foundation
import simd
import FoldCore
import FoldGeometry
@testable import FoldEngine

@Suite("Thermal and low-power degradation")
struct ThermalPolicyTests {

    let policy = ThermalPolicy(nominalFrameRate: 60)

    @Test("cool and plugged in runs at full rate with the accurate assigner")
    func nominal() {
        let d = policy.decide(.init(thermalState: .nominal, lowPowerMode: false))
        #expect(d.frameRate == 60)
        #expect(d.assigner == .learned)
    }

    /// The shape PLAN.md asks for: less work per second, not fewer frames out of a 60 fps
    /// stream. Frame rate must fall monotonically as heat rises, and never to zero.
    @Test("frame rate falls monotonically with heat and never stops")
    func monotonic() {
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        var previous = Float.greatestFiniteMagnitude
        for state in states {
            let d = policy.decide(.init(thermalState: state))
            #expect(d.frameRate <= previous, "\(state) raised the frame rate")
            #expect(d.frameRate > 0, "the fold must never stop entirely")
            previous = d.frameRate
        }
    }

    @Test("critical heat switches to the cheaper assigner")
    func criticalUsesCheaperAssigner() {
        #expect(policy.decide(.init(thermalState: .serious)).assigner == .learned)
        #expect(policy.decide(.init(thermalState: .critical)).assigner == .pSEA)
        // And the fallback is a real method, not a stub: it still assigns structure.
        let ca = (0..<24).map { k -> SIMD3<Float> in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
        let assigned = SecondaryStructureAssigner.pSEA.assign(caPositions: ca)
        #expect(assigned.contains { $0.structure == .helix })
    }

    @Test("low power mode is honoured even when the device is cool")
    func lowPowerMode() {
        let d = policy.decide(.init(thermalState: .nominal, lowPowerMode: true))
        #expect(d.frameRate == 30)
        #expect(d.explanation.contains("Low Power"))
    }

    @Test("serious heat outranks low power mode rather than being masked by it")
    func heatOutranksLowPower() {
        let hot = policy.decide(.init(thermalState: .critical, lowPowerMode: true))
        #expect(hot.frameRate == 20)
        #expect(hot.assigner == .pSEA)
    }

    @Test("every decision carries an explanation to surface honestly")
    func explanations() {
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                let d = policy.decide(.init(thermalState: state, lowPowerMode: lowPower))
                #expect(!d.explanation.isEmpty)
            }
        }
    }

    /// Degrading must change the pacing, not truncate the trajectory: the same fold at half
    /// the frame rate produces about half the frames and still starts and ends in the same
    /// place.
    @Test("degrading reduces frames without truncating the trajectory")
    func degradationKeepsTheWholeFold() async throws {
        let provider = try FoldEngineTests.provider("genie2_76aa_seed1")

        func play(frameRate: Float) async throws -> (count: Int, firstRg: Float, lastRg: Float) {
            let engine = FoldEngine(configuration: .init(frameRate: frameRate,
                                                         secondsPerRawFrame: 1.0 / 12.0))
            var count = 0
            var first: Float = 0
            var last: Float = 0
            for await frame in try await engine.frames(for: provider) {
                if count == 0 { first = frame.radiusOfGyration }
                last = frame.radiusOfGyration
                count += 1
            }
            return (count, first, last)
        }

        let full = try await play(frameRate: 60)
        let half = try await play(frameRate: 30)
        #expect(half.count < full.count)
        #expect(Double(half.count) > Double(full.count) * 0.4)
        // Both must traverse the whole fold: same start, same end.
        #expect(abs(half.firstRg - full.firstRg) < 0.01)
        #expect(abs(half.lastRg - full.lastRg) < 0.01)
    }

    @Test("the engine adopts a policy decision")
    func engineAdapts() async throws {
        let engine = FoldEngine(configuration: .init(frameRate: 60))
        let decision = await engine.adapt(to: .init(thermalState: .critical))
        #expect(decision.assigner == .pSEA)
        let configuration = await engine.configuration
        #expect(configuration.frameRate == 20)
        #expect(configuration.assigner == .pSEA)
    }

    @Test("reading the real device conditions does not trap")
    func currentConditions() {
        let conditions = ThermalPolicy.Conditions.current
        let decision = policy.decide(conditions)
        #expect(decision.frameRate > 0)
    }
}

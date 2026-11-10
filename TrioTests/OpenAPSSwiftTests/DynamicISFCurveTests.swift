import Foundation
import Testing
@testable import Trio

/// The Dynamic ISF graph must show exactly what the algorithm (DynamicISF.swift) computes.
@Suite("Dynamic ISF graph") struct DynamicISFCurveTests {
    private func inputs(
        sens: Decimal = 50,
        past2h: Decimal = 30,
        tenDay: Decimal = 30,
        currentTDD: Decimal = 30,
        useOverride: Bool = false
    ) -> (Profile, Preferences, TrioCustomOrefVariables) {
        var preferences = Preferences()
        preferences.autosensMin = 0.7
        preferences.autosensMax = 1.2
        preferences.curve = .rapidActing
        preferences.useCustomPeakTime = false

        var profile = Profile()
        profile.sens = sens
        profile.minBg = 100

        let variables = TrioCustomOrefVariables(
            average_total_data: tenDay,
            weightedAverage: 1,
            currentTDD: currentTDD,
            past2hoursAverage: past2h,
            date: Date(),
            overridePercentage: 50,
            useOverride: useOverride,
            duration: 0,
            unlimited: true,
            overrideTarget: 0,
            smbIsOff: false,
            advancedSettings: false,
            isfAndCr: false,
            isf: true,
            cr: true,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 30,
            uamMinutes: 30
        )
        return (profile, preferences, variables)
    }

    private func live(sigmoid: Bool = false, af: Decimal = 0.8, weight: Decimal = 0.35) -> DynamicISFCurve.LiveSettings {
        .init(
            useNewFormula: true,
            sigmoid: sigmoid,
            adjustmentFactor: af,
            adjustmentFactorSigmoid: 0.5,
            weightPercentage: weight
        )
    }

    /// What the algorithm itself would use, computed independently of the graph code.
    private func algorithmISF(
        glucose: Decimal, profile: Profile, preferences: Preferences, variables: TrioCustomOrefVariables,
        live: DynamicISFCurve.LiveSettings
    ) -> Decimal {
        var preferences = preferences
        preferences.useNewFormula = true
        preferences.sigmoid = live.sigmoid
        preferences.adjustmentFactor = live.adjustmentFactor
        preferences.adjustmentFactorSigmoid = live.adjustmentFactorSigmoid
        var profile = profile
        profile.weightPercentage = live.weightPercentage
        var variables = variables
        variables.weightedAverage = live.weightPercentage * variables.past2hoursAverage
            + (1 - live.weightPercentage) * variables.average_total_data
        let result = DynamicISF.calculate(
            profile: profile, preferences: preferences, currentGlucose: glucose, trioCustomOrefVariables: variables
        )!
        return DeterminationGenerator.computeAdjustedSensitivity(
            sensitivity: profile.sens!, sensitivityRatio: result.ratio, trioCustomOrefVariables: variables
        )
    }

    @Test("Logarithmic graph matches DynamicISF.swift at several glucose values") func logarithmicMatchesAlgorithm() throws {
        let (profile, preferences, variables) = inputs(past2h: 40, tenDay: 28)
        let settings = live(af: 0.9, weight: 0.35)
        let curve = try #require(DynamicISFCurve.make(
            profile: profile, preferences: preferences, trioCustomOrefVariables: variables, live: settings
        ))
        for glucose: Decimal in [60, 80, 120, 150, 200, 300, 400] {
            let expected = algorithmISF(
                glucose: glucose,
                profile: profile,
                preferences: preferences,
                variables: variables,
                live: settings
            )
            #expect(curve.isf(at: glucose) == expected, "ISF at \(glucose)")
        }
    }

    @Test("Sigmoid graph matches DynamicISF.swift at several glucose values") func sigmoidMatchesAlgorithm() throws {
        let (profile, preferences, variables) = inputs()
        let settings = live(sigmoid: true)
        let curve = try #require(DynamicISFCurve.make(
            profile: profile, preferences: preferences, trioCustomOrefVariables: variables, live: settings
        ))
        #expect(curve.isSigmoid)
        for glucose: Decimal in [70, 100, 150, 250] {
            let expected = algorithmISF(
                glucose: glucose,
                profile: profile,
                preferences: preferences,
                variables: variables,
                live: settings
            )
            #expect(curve.isf(at: glucose) == expected, "ISF at \(glucose)")
        }
    }

    @Test("Matches the logarithmic formula by hand, including clamping to Autosens limits") func handComputedValues() throws {
        // ISF 50, AF 80%, TDD 30, rapid-acting insulin (insulin factor 120 − 65 = 55)
        let (profile, preferences, variables) = inputs()
        let curve = try #require(DynamicISFCurve.make(
            profile: profile, preferences: preferences, trioCustomOrefVariables: variables, live: live()
        ))
        // 120 mg/dL: ratio = 50 × 0.8 × 30 × ln(120/55 + 1) / 1800 = 0.7717 → ISF 50 / 0.7717 = 64.8
        #expect(curve.isf(at: 120) == 64.8)
        // 40 mg/dL: ratio 0.364 is below Autosens Min 0.7 → clamped → ISF 50 / 0.7 = 71.4
        #expect(curve.isf(at: 40) == 71.4)
        // 400 mg/dL: ratio is above Autosens Max 1.2 → clamped → ISF 50 / 1.2 = 41.7
        #expect(curve.isf(at: 400) == 41.7)
        #expect(curve.strongestISF == Decimal(50) / Decimal(1.2))
        #expect(curve.weakestISF == Decimal(50) / Decimal(0.7))
        // Every point stays inside the allowed band.
        for point in curve.points {
            #expect(point.isf >= (curve.strongestISF * 10).rounded(scale: 0) / 10 - 0.1)
            #expect(point.isf <= (curve.weakestISF * 10).rounded(scale: 0) / 10 + 0.1)
        }
    }

    @Test("Weighted TDD uses the on-screen Weighted Average of TDD") func weightedTDD() {
        let (_, _, variables) = inputs(past2h: 40, tenDay: 20)
        #expect(DynamicISFCurve.weightedTDD(variables: variables, weightPercentage: 0.35) == 27)
        #expect(DynamicISFCurve.weightedTDD(variables: variables, weightPercentage: 0.5) == 30)
        let (_, _, empty) = inputs(currentTDD: 0)
        #expect(DynamicISFCurve.weightedTDD(variables: empty, weightPercentage: 0.35) == 1)
    }

    @Test("Ignores an active override so the graph shows her base settings") func ignoresOverride() throws {
        let (profile, preferences, variables) = inputs(useOverride: true)
        let curve = try #require(DynamicISFCurve.make(
            profile: profile, preferences: preferences, trioCustomOrefVariables: variables, live: live()
        ))
        #expect(curve.profileISF == 50)
    }

    @Test("No graph when Dynamic ISF is off") func disabled() {
        let (profile, preferences, variables) = inputs()
        var settings = live()
        settings.useNewFormula = false
        #expect(
            DynamicISFCurve
                .make(profile: profile, preferences: preferences, trioCustomOrefVariables: variables, live: settings) == nil
        )
    }
}

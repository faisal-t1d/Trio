import Foundation

/// Builds the Dynamic ISF curve shown on the Dynamic Settings screen: the ISF Trio would use
/// at each glucose value, given the current settings.
///
/// DISPLAY ONLY. This never changes settings or dosing. Every point is computed by calling the
/// algorithm's own `DynamicISF.calculate` and `DeterminationGenerator.computeAdjustedSensitivity`,
/// so the graph cannot drift from what the loop actually does.
enum DynamicISFCurve {
    struct Point: Identifiable, Equatable {
        /// Glucose in mg/dL.
        let glucose: Decimal
        /// ISF (mg/dL per U) the algorithm would use at this glucose, after clamping.
        let isf: Decimal
        /// Dynamic ratio after clamping to Autosens Min/Max.
        let ratio: Decimal
        /// True when the ratio hit Autosens Min or Max.
        let isClamped: Bool
        var id: Decimal { glucose }
    }

    struct Curve: Equatable {
        let points: [Point]
        /// Profile ISF (mg/dL per U) for the current time of day.
        let profileISF: Decimal
        /// Strongest allowed ISF: profile ISF ÷ Autosens Max.
        let strongestISF: Decimal
        /// Weakest allowed ISF: profile ISF ÷ Autosens Min.
        let weakestISF: Decimal
        /// The weighted TDD the formula used.
        let tdd: Decimal
        let isSigmoid: Bool

        /// The ISF at a given glucose (nearest computed point).
        func isf(at glucose: Decimal) -> Decimal? {
            points.min { abs($0.glucose - glucose) < abs($1.glucose - glucose) }?.isf
        }
    }

    /// The live values from the Dynamic Settings screen, applied on top of the saved inputs.
    struct LiveSettings: Equatable {
        var useNewFormula: Bool
        var sigmoid: Bool
        var adjustmentFactor: Decimal
        var adjustmentFactorSigmoid: Decimal
        var weightPercentage: Decimal
    }

    static let glucoseRange: ClosedRange<Decimal> = 40 ... 400

    /// - Parameters:
    ///   - profile: The profile the algorithm last used (`settings/profile.json`).
    ///   - preferences: Saved preferences (Autosens limits, insulin curve and peak time).
    ///   - trioCustomOrefVariables: TDD inputs the algorithm last used (`monitor/trio_custom_oref_variables.json`).
    ///   - live: Values being edited on screen; they replace the saved ones for this preview.
    ///   - now: Time of day used to pick the profile ISF.
    /// - Returns: `nil` when Dynamic ISF would be off for these inputs.
    static func make(
        profile savedProfile: Profile,
        preferences savedPreferences: Preferences,
        trioCustomOrefVariables savedVariables: TrioCustomOrefVariables,
        live: LiveSettings,
        now: Date = Date(),
        step: Decimal = 2
    ) -> Curve? {
        var preferences = savedPreferences
        preferences.useNewFormula = live.useNewFormula
        preferences.sigmoid = live.sigmoid
        preferences.adjustmentFactor = live.adjustmentFactor
        preferences.adjustmentFactorSigmoid = live.adjustmentFactorSigmoid
        preferences.weightPercentage = live.weightPercentage

        var profile = savedProfile
        profile.autosensMax = preferences.autosensMax
        profile.autosensMin = preferences.autosensMin
        profile.curve = preferences.curve
        profile.useCustomPeakTime = preferences.useCustomPeakTime
        profile.insulinPeakTime = preferences.insulinPeakTime
        profile.weightPercentage = live.weightPercentage
        // Show the curve for her base settings, without a temp target in effect.
        profile.temptargetSet = false
        if profile.sens == nil { profile.sens = profile.sensitivityFor(time: now) }

        var variables = savedVariables
        // Without an override, so the curve reflects her settings alone.
        variables.useOverride = false
        variables.weightedAverage = weightedTDD(variables: variables, weightPercentage: live.weightPercentage)

        guard let sensitivity = profile.sens, sensitivity > 0 else { return nil }
        let minLimit = min(profile.autosensMin, profile.autosensMax)
        let maxLimit = max(profile.autosensMin, profile.autosensMax)

        var points = [Point]()
        var glucose = glucoseRange.lowerBound
        while glucose <= glucoseRange.upperBound {
            guard let result = DynamicISF.calculate(
                profile: profile,
                preferences: preferences,
                currentGlucose: glucose,
                trioCustomOrefVariables: variables
            ) else { return nil }
            let isf = DeterminationGenerator.computeAdjustedSensitivity(
                sensitivity: sensitivity,
                sensitivityRatio: result.ratio,
                trioCustomOrefVariables: variables
            )
            points.append(Point(glucose: glucose, isf: isf, ratio: result.ratio, isClamped: result.limitValue != nil))
            glucose += step
        }

        return Curve(
            points: points,
            profileISF: sensitivity,
            strongestISF: sensitivity / maxLimit,
            weakestISF: sensitivity / minLimit,
            tdd: variables.tdd(profile: profile),
            isSigmoid: preferences.sigmoid
        )
    }

    /// Weighted TDD, re-weighted for the on-screen "Weighted Average of TDD" value.
    /// Same formula as `OpenAPS.prepareTrioCustomOrefVariables`:
    /// weight × past-2-hours average + (1 − weight) × 10-day average (1 when there's no TDD yet).
    static func weightedTDD(variables: TrioCustomOrefVariables, weightPercentage: Decimal) -> Decimal {
        guard variables.currentTDD > 0 else { return 1 }
        return weightPercentage * variables.past2hoursAverage + (1 - weightPercentage) * variables.average_total_data
    }
}

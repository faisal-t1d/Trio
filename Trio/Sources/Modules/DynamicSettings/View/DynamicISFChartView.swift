import Charts
import SwiftUI

/// Graph of the ISF Trio would use at each glucose value (like the TrioDocs Desmos graphs).
/// Display only.
struct DynamicISFChartView: View {
    let curve: DynamicISFCurve.Curve
    let units: GlucoseUnits

    @State private var selectedGlucose: Decimal?

    /// Unrounded value in the user's units, so the plotted curve stays smooth in mmol/L.
    private func display(_ mgdl: Decimal) -> Double {
        Double(truncating: (units == .mmolL ? mgdl * GlucoseUnits.exchangeRate : mgdl) as NSNumber)
    }

    private func text(_ mgdl: Decimal) -> String {
        units == .mmolL ? String(format: "%.1f", display(mgdl)) : String(format: "%.0f", display(mgdl))
    }

    private var footnote: String {
        let limits = "The ISF stays between your Autosens Min and Max limits (shaded)."
        if curve.isSigmoid { return "Sigmoid curve. " + limits }
        let tip = "TrioDocs suggests an Adjustment Factor that gives your profile ISF at about"
        return "\(tip) \(text(150)) \(unitLabel). " + limits
    }

    /// Short lines on purpose: Trio's formatter wraps long lines, which can break string interpolation.
    private var inputsNote: String {
        let tdd = String(format: "%.1f", Double(truncating: curve.tdd as NSNumber))
        let rest = "your profile ISF for this time of day, and no override or temp target."
        return "Uses your weighted TDD of \(tdd) U, " + rest + " Preview only; it does not change dosing."
    }

    private var unitLabel: String { units == .mmolL ? "mmol/L" : "mg/dL" }
    private var readoutGlucose: Decimal { selectedGlucose ?? 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout
            chart.frame(height: 230)
            legend
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(inputsNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var readout: some View {
        let isf = curve.isf(at: readoutGlucose) ?? curve.profileISF
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    selectedGlucose == nil ? "At \(text(readoutGlucose)) \(unitLabel)" :
                        "At \(text(readoutGlucose)) \(unitLabel) (drag)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("ISF \(text(isf)) \(unitLabel)/U")
                    .font(.headline)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Profile ISF").font(.caption).foregroundStyle(.secondary)
                Text("\(text(curve.profileISF))").font(.headline).monospacedDigit()
            }
        }
    }

    private var chart: some View {
        Chart {
            RectangleMark(
                xStart: .value("Low", display(DynamicISFCurve.glucoseRange.lowerBound)),
                xEnd: .value("High", display(DynamicISFCurve.glucoseRange.upperBound)),
                yStart: .value("Strongest", display(curve.strongestISF)),
                yEnd: .value("Weakest", display(curve.weakestISF))
            )
            .foregroundStyle(Color.green.opacity(0.12))

            RuleMark(y: .value("Profile ISF", display(curve.profileISF)))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(curve.points) { point in
                LineMark(
                    x: .value("Glucose", display(point.glucose)),
                    y: .value("ISF", display(point.isf))
                )
                .foregroundStyle(Color.insulin)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.monotone)
            }

            if let selectedGlucose, let isf = curve.isf(at: selectedGlucose) {
                RuleMark(x: .value("Selected", display(selectedGlucose)))
                    .foregroundStyle(Color.primary.opacity(0.4))
                PointMark(x: .value("Selected", display(selectedGlucose)), y: .value("ISF", display(isf)))
                    .foregroundStyle(Color.insulin)
                    .symbolSize(70)
            }
        }
        .chartXScale(
            domain: display(DynamicISFCurve.glucoseRange.lowerBound) ...
                display(DynamicISFCurve.glucoseRange.upperBound)
        )
        .chartYScale(domain: 0 ... display(curve.weakestISF) * 1.15)
        .chartXAxisLabel("Glucose (\(unitLabel))")
        .chartYAxisLabel("ISF (\(unitLabel)/U)")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plot = proxy.plotFrame,
                                      let x: Double = proxy.value(atX: value.location.x - geometry[plot].origin.x)
                                else { return }
                                let mgdl = units == .mmolL ? Decimal(x) / GlucoseUnits.exchangeRate : Decimal(x)
                                selectedGlucose = min(
                                    max(mgdl, DynamicISFCurve.glucoseRange.lowerBound),
                                    DynamicISFCurve.glucoseRange.upperBound
                                )
                            }
                            .onEnded { _ in selectedGlucose = nil }
                    )
            }
        }
        .accessibilityLabel("Dynamic ISF graph")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .insulin, dashed: false, label: "Dynamic ISF")
            legendItem(color: .secondary, dashed: true, label: "Profile ISF")
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.25)).frame(width: 14, height: 10)
                Text("Allowed range").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func legendItem(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 14, height: dashed ? 1 : 2.5)
                .mask(dashed ? AnyView(HStack(spacing: 2) { ForEach(0 ..< 4) { _ in
                    Rectangle().frame(width: 2) } }) : AnyView(Rectangle()))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

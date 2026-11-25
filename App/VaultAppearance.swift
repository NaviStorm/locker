import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static let lockerTint = Color("VaultAccent")
    static let lockerCanvas = Color("VaultCanvas")
}

extension View {
    func vaultFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.lockerCanvas)
    }
}

struct VaultGlyph: View {
    let symbol: String
    var color: Color = .lockerTint
    @ScaledMetric(relativeTo: .body) private var side = 36.0

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: side * 0.28))
            .accessibilityHidden(true)
    }
}

struct DocumentGlyph: View {
    let name: String

    var body: some View {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .pdf) == true { VaultGlyph(symbol: "doc.richtext", color: .red) }
        else if type?.conforms(to: .image) == true { VaultGlyph(symbol: "photo", color: .teal) }
        else if type?.conforms(to: .archive) == true { VaultGlyph(symbol: "archivebox", color: .orange) }
        else if type?.conforms(to: .spreadsheet) == true { VaultGlyph(symbol: "tablecells", color: .green) }
        else { VaultGlyph(symbol: "doc.text", color: .blue) }
    }
}

struct LockerCover: View {
    let compact: Bool

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
        layout {
            Image("LockerMark")
                .resizable().interpolation(.high)
                .frame(width: compact ? 58 : 82, height: compact ? 58 : 82)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 15 : 21))
                .accessibilityHidden(true)
            Text("Locker")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(compact ? 24 : 32)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: compact ? .leading : .bottomLeading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.19),
                                        Color(red: 0.23, green: 0.15, blue: 0.37)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                Canvas { context, size in
                    let center = CGPoint(x: size.width * 0.95, y: size.height * 0.08)
                    for radius in stride(from: 32.0, through: max(size.width, size.height) * 1.5, by: 28) {
                        let circle = CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)
                        context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.085)), lineWidth: 1)
                    }
                }.accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

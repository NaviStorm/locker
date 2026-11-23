import SwiftUI

struct LargePDFScreen: View {
    let pdf: PagedPDF
    @State private var number = 1
    @State private var image: CGImage?
    @State private var problem: String?
    var body: some View {
        VStack {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if let problem { Text(problem) }
            else { ProgressView() }
            Stepper("Page \(number) sur \(pdf.pages)", value: $number, in: 1...pdf.pages)
                .padding().frame(maxWidth: 330)
        }
        .task(id: number) {
            image = nil
            problem = nil
            do {
                let result = try await pdf.render(number)
                if !Task.isCancelled { image = result }
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
}

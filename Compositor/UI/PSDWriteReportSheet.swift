import SwiftUI

/// Asks before a Photoshop save that changes what the document holds: shown only when the writer's report has a lossy
/// item (an adjustment Photoshop lacks written as pixels, a clipping applied to pixels or left out, a curve resampled,
/// a shape saved as pixels or a plain path, alpha channels or an adjustment's vector mask left out). Lists those first,
/// then the report's notes. Nothing is written until Save.
struct PSDWriteReportSheet: View {
    let fileName: String
    let warnings: [PSDWriteWarning]
    let finish: (Bool) -> Void

    /// Lossy items first, each group in the writer's order.
    private var listed: [PSDWriteWarning] { warnings.filter(\.lossy) + warnings.filter { !$0.lossy } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save “\(fileName)” as a Photoshop file?").font(.title2.bold())
            Text("Photoshop can’t hold everything in this document, so the file will differ from it as listed. The document itself doesn’t change; a Compositor project keeps everything.")
                .foregroundStyle(.secondary)
            List(listed.indices, id: \.self) { index in
                let warning = listed[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text(warning.layerName).font(.headline)
                    Text(warning.message)
                }.padding(.vertical, 4)
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Save") { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .roundedControls()
    }
}

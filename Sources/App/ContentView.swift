import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72))
                .foregroundStyle(.blue, .secondary)

            Text("XISF Quick Look")
                .font(.largeTitle.bold())

            Text("Finder thumbnails and Quick Look previews for PixInsight XISF files, with automatic STF stretch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            Divider()
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 10) {
                Label("Move this app to /Applications", systemImage: "1.circle.fill")
                Label("Launch it once to register the extensions", systemImage: "2.circle.fill")
                Label("In Terminal: qlmanage -r && killall Finder", systemImage: "3.circle.fill")
                Label("Space-bar on any .xisf file to preview", systemImage: "4.circle.fill")
            }
            .font(.callout)
            .padding(.horizontal, 20)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
    }
}

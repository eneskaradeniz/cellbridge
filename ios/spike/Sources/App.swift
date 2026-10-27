import SwiftUI

@main
struct SpikeApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @AppStorage("serverURL") private var url = "ws://192.168.1.104:8765"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("ws://host:port", text: $url)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack {
                Button("Start") { model.start(url: url) }.buttonStyle(.borderedProminent)
                Text(model.status).font(.footnote)
            }
            ScrollView {
                Text(model.logText).font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}

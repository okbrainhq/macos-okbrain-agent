import SwiftUI

struct DiagnosticsView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 12) {
        GridRow {
          Text("Transport")
            .foregroundStyle(.secondary)
          Text("ssh-unix-socket")
            .font(.callout.monospaced())
        }

        GridRow {
          Text("Socket Mode")
            .foregroundStyle(.secondary)
          Text("0600")
            .font(.callout.monospaced())
        }

        GridRow {
          Text("Screen Recording")
            .foregroundStyle(.secondary)
          Text(store.permissions.screenRecording.rawValue)
            .font(.callout.monospaced())
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Latest Response")
          .font(.headline)

        ScrollView {
          Text(store.latestProtocolResponse.isEmpty ? "{}" : store.latestProtocolResponse)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
        }
        .frame(minHeight: 180, maxHeight: 300)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

import SwiftUI

struct ScreenshotView: View {
  @EnvironmentObject private var store: AgentRuntimeStore

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Button {
          store.captureFullScreenProbe()
        } label: {
          Label("Capture Full Screen", systemImage: "camera.viewfinder")
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isCapturing)

        if store.isCapturing {
          ProgressView()
            .controlSize(.small)
        }

        Spacer()

        StatusPill(
          title: store.permissions.screenRecording.label,
          systemImage: store.permissions.screenRecording.systemImage,
          tint: store.permissions.screenRecording.tint
        )
      }

      if let screenshot = store.latestScreenshot {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline) {
            Text("\(screenshot.width) x \(screenshot.height)")
              .font(.headline)
            Text(screenshot.capturedAt, style: .time)
              .foregroundStyle(.secondary)
            Spacer()
          }

          Image(nsImage: screenshot.image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 380, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
            }
        }
      } else {
        ContentUnavailableView(
          "No Screenshot",
          systemImage: "camera.viewfinder",
          description: Text("Run a capture probe to preview the PNG returned by the socket protocol.")
        )
        .frame(maxWidth: .infinity, minHeight: 300)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

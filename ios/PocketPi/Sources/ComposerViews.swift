import PocketPiKit
import SwiftUI

/// Stops the composer's running shell command (set by the chat screen).
extension EnvironmentValues {
    @Entry var abortBash: (@MainActor () -> Void)? = nil
}

/// A shell command from the composer (`!cmd`), live as it runs and the same
/// once reloaded from pi's `bashExecution` message. Looks like a bash tool
/// card; open while it runs, with a Stop button.
struct BashCard: View {
    let run: BashRun
    @Environment(\.abortBash) private var abortBash
    @State private var open = false
    @State private var showAll = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { open || run.running }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                if !run.output.isEmpty {
                    let long = run.output.count > 4000 && !showAll
                    Text(long ? "…" + String(run.output.suffix(4000)) : run.output)
                        .font(.caption.monospaced())
                        .foregroundStyle(run.isError ? Theme.danger : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if long { Button("Show all \(run.output.count) characters") { showAll = true }.font(.caption) }
                }
                if run.truncated {
                    Text("Output truncated" + (run.fullOutputPath.map { " · full output in \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if run.running, let abortBash {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { abortBash() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("stop-bash")
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.caption).frame(width: 16)
                Text(run.excludeFromContext ? "!!" : "!").font(.footnote.monospaced().weight(.semibold))
                Text(run.command).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                status
            }
            .foregroundStyle(.primary)
        }
        .tint(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .accessibilityIdentifier("bash-card")
    }

    @ViewBuilder private var status: some View {
        if run.running {
            ProgressView().controlSize(.mini)
        } else if !run.status.isEmpty {
            Text(run.status).font(.caption2.monospaced())
                .foregroundStyle(run.isError ? Theme.danger : .secondary)
        }
    }
}

/// pi waiting to try the model again: a countdown and "Stop retrying".
struct RetryBanner: View {
    let retry: RetryState
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    Text(retry.line(now: ctx.date)).font(.footnote.weight(.semibold))
                    if !retry.errorMessage.isEmpty {
                        Text(retry.errorMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Stop retrying", action: stop)
                .font(.footnote)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stop-retrying")
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("retry-banner")
    }
}

/// A message waiting in pi's queue: steering goes after the current tool
/// calls, "after" ones once the whole turn ends.
struct QueuedMessage: View {
    let text: String
    let after: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(after ? "after" : "steer")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text).font(.footnote).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

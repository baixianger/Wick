import SwiftUI
import TradingFloor
import UniformTypeIdentifiers

/// Inlined into the existing Provider form; no token is ever bound to a field.
struct CodexAccountView: View {
    @Bindable var account: CodexAccount
    @Environment(\.openURL) private var openURL
    @State private var importing = false
    @State private var callback = ""
    @State private var importError: String?

    var body: some View {
        LabeledContent("Account", value: account.accountLabel ?? String(localized: "Not signed in", locale: LocaleHolder.current))
        Text("Use your ChatGPT subscription. No API key or Codex installation is required. Wick keeps its own login in Keychain.")
            .font(.caption).foregroundStyle(.secondary)
        if account.isLoggingIn {
            if let device = account.deviceLogin {
                LabeledContent("One-time code") {
                    Text(device.userCode).monospaced().textSelection(.enabled)
                }
                Button("Open ChatGPT sign-in") { openURL(device.verificationURL) }
                Text("Enter this code on the sign-in page. Wick will finish signing in automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let browser = account.browserLogin {
                Button("Open browser sign-in") { openURL(browser.url) }
                Text("After signing in, copy the full localhost callback URL from your browser and paste it below. That page may not load; Wick completes the login here.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Callback URL", text: $callback)
                Button("Complete sign-in") {
                    account.finishBrowser(callback: callback)
                    callback = ""
                }.disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                ProgressView("Starting sign-in…")
            }
            Button("Cancel sign-in", role: .cancel) { account.cancelLogin(); callback = "" }
        } else {
            HStack {
                Button("Sign in with ChatGPT") { account.signInWithDeviceCode() }
                Menu("More options") {
                    Button("Browser sign-in (manual callback)") {
                        account.signInWithBrowser()
                        if let url = account.browserLogin?.url { openURL(url) }
                    }
                    Button("Import Codex credentials…") { importing = true }
                }
                if account.isSignedIn {
                    Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                }
            }
        }
        if let error = account.error ?? importError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        if account.isSignedIn {
            Button(LocalizedStringKey(account.loadingUsage ? "Refreshing usage…" : "Refresh usage")) {
                Task { await account.refreshUsage(force: true) }
            }.disabled(account.loadingUsage)
            if let usage = account.usage {
                if let plan = usage.plan { LabeledContent("Plan", value: plan) }
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(window.name) · \(windowDuration(window.seconds)): \(Int(window.remainingPercent))% remaining")
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
                if usage.windows.isEmpty { Text("Usage windows are unknown.").font(.caption) }
                Text("Updated \(usage.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = account.usageError { Text(error).font(.caption).foregroundStyle(.secondary) }
            Text("Sign out removes only Wick's saved login. Codex keeps its own credentials.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // macOS grants access to only the explicitly selected file.
        Color.clear.frame(height: 0)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    importError = nil
                    Task { await account.importLogin(from: url) }
                case .failure: importError = "Could not open the selected login file."
                }
            }
            .task { await account.refreshStatus() }
            .onDisappear { account.cancelLogin(); callback = "" }
    }

    private func windowDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }
}

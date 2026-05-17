import SwiftUI

struct SetupWizardView: View {
    enum Step: Int, CaseIterable { case intro, credentials, authChallenge, discover, archive, launchAtLogin, done }

    let close: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridge: EufyBridge
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var keychain: KeychainStore

    @State private var step: Step = .intro
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var country: String = "GB"
    @State private var captchaInput: String = ""
    @State private var verifyCode: String = ""
    @State private var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set up PorchKeep").font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .onChange(of: bridge.authChallenge) { _, newValue in
            if newValue != nil { step = .authChallenge }
        }
        .onChange(of: bridge.state) { _, newState in
            if newState == .ready && (step == .credentials || step == .authChallenge) {
                step = .discover
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro:
            VStack(alignment: .leading, spacing: 12) {
                Text("Use a dedicated eufy account.").font(.headline)
                Text("Logging the bridge in can sign your phone app out. To avoid that:")
                Text("1. In the eufy app on your phone, go to Settings → Family Settings.\n2. Create a new eufy account with a different email.\n3. Invite that account to your home as an Admin or Member.\n4. Make sure it can see the doorbell.\n5. Use those credentials on the next screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .credentials:
            VStack(alignment: .leading, spacing: 12) {
                Text("eufy account credentials").font(.headline)
                Text("Stored only in this Mac's Keychain. Never sent anywhere except the eufy cloud.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Email") { TextField("", text: $email).textFieldStyle(.roundedBorder) }
                LabeledContent("Password") { SecureField("", text: $password).textFieldStyle(.roundedBorder) }
                LabeledContent("Country") {
                    TextField("GB", text: $country).textFieldStyle(.roundedBorder).frame(width: 80)
                }
                if bridge.state == .connecting || bridge.state == .authenticating {
                    HStack { ProgressView().controlSize(.small); Text("Signing in…").font(.caption) }
                }
            }
        case .authChallenge:
            authChallengeView
        case .discover:
            VStack(alignment: .leading, spacing: 12) {
                Text("Doorbell discovery").font(.headline)
                if bridge.discoveredDevices.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Looking for devices on this account…") }
                } else {
                    Text("Pick the doorbell you want PorchKeep to monitor:")
                    Picker("Doorbell", selection: $settings.knownDeviceSerial) {
                        ForEach(bridge.discoveredDevices) { d in
                            Text("\(d.name) (\(d.serialNumber))").tag(d.serialNumber)
                        }
                    }
                    .labelsHidden()
                }
            }
        case .archive:
            VStack(alignment: .leading, spacing: 12) {
                Text("Archive folder & retention").font(.headline)
                Text("Clips will be written to:")
                Text(settings.archiveRoot.path).font(.callout.monospaced()).textSelection(.enabled)
                Stepper("Keep clips for \(settings.retentionDays) day(s)", value: $settings.retentionDays, in: 7...90)
                Stepper("Max clip length: \(settings.maxClipSeconds)s", value: $settings.maxClipSeconds, in: 30...300, step: 10)
                Stepper("Live view idle timeout: \(settings.liveIdleTimeoutSeconds)s", value: $settings.liveIdleTimeoutSeconds, in: 30...600, step: 15)
            }
        case .launchAtLogin:
            VStack(alignment: .leading, spacing: 12) {
                Text("Launch at login").font(.headline)
                Toggle("Start PorchKeep when I log in", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, on in
                        do { try LaunchAtLogin.setEnabled(on) }
                        catch { appState.lastError = error.localizedDescription }
                    }
                Text("You can change this any time from Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 12) {
                Text("All set.").font(.headline)
                Text("PorchKeep will sit in the menu bar. Motion and ring events get captured automatically. Tap “View Live” when you want to see the doorbell — that wakes it and uses battery.")
            }
        }
    }

    @ViewBuilder private var authChallengeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .captcha(let id, let img)? = bridge.authChallenge?.kind {
                Text("Captcha required").font(.headline)
                if let data = Data(base64Encoded: stripDataURL(img)),
                   let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                } else {
                    Text("(captcha image could not be decoded)").foregroundStyle(.red)
                }
                LabeledContent("Captcha") { TextField("", text: $captchaInput).textFieldStyle(.roundedBorder) }
                Button("Submit captcha") {
                    Task {
                        try? await bridge.submitCaptcha(captchaInput, captchaId: id)
                        captchaInput = ""
                    }
                }
            } else if case .verifyCode? = bridge.authChallenge?.kind {
                Text("2FA verify code").font(.headline)
                Text("Check the email or SMS the eufy cloud just sent.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Code") { TextField("", text: $verifyCode).textFieldStyle(.roundedBorder) }
                Button("Submit code") {
                    Task {
                        try? await bridge.submitVerifyCode(verifyCode)
                        verifyCode = ""
                    }
                }
            } else if bridge.state == .error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign-in failed").font(.headline)
                        Text(bridge.lastError ?? "The bridge could not authenticate.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") {
                            Task {
                                await bridge.stop()
                                await bridge.start()
                            }
                        }
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Authenticating…") }
            }
        }
    }

    private func stripDataURL(_ s: String) -> String {
        if let comma = s.firstIndex(of: ",") { return String(s[s.index(after: comma)...]) }
        return s
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if step != .intro {
                Button("Back") { goBack() }
            }
            Spacer()
            Button(primaryLabel) { Task { await primaryAction() } }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
    }

    private var primaryLabel: String {
        switch step {
        case .intro: return "Continue"
        case .credentials: return "Sign in"
        case .authChallenge: return "Continue"
        case .discover: return "Use this doorbell"
        case .archive: return "Continue"
        case .launchAtLogin: return "Continue"
        case .done: return "Finish"
        }
    }

    private var primaryDisabled: Bool {
        switch step {
        case .credentials: return email.isEmpty || password.isEmpty
        case .discover: return settings.knownDeviceSerial.isEmpty
        case .authChallenge: return bridge.state != .ready
        default: return false
        }
    }

    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    private func primaryAction() async {
        switch step {
        case .intro:
            step = .credentials
        case .credentials:
            settings.country = country
            keychain.saveCredentials(username: email, password: password)
            await bridge.stop()
            await bridge.start()
            step = .authChallenge
        case .authChallenge:
            if bridge.state == .ready { step = .discover }
        case .discover:
            if let d = bridge.discoveredDevices.first(where: { $0.serialNumber == settings.knownDeviceSerial }) {
                settings.knownDeviceName = d.name
            }
            step = .archive
        case .archive:
            step = .launchAtLogin
        case .launchAtLogin:
            step = .done
        case .done:
            settings.isConfigured = true
            close()
        }
    }
}

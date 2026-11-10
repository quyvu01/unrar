import SwiftUI

struct PasswordPrompt: View {
    let model: ArchiveViewModel

    @State private var password = ""
    @State private var reveal = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 4) {
                Text("Enter Password")
                    .font(.title3.weight(.semibold))
                Text("“\(model.pendingArchiveName)” is protected by a password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Group {
                    if reveal {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)

                Button {
                    reveal.toggle()
                    focused = true
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(reveal ? Text("Hide password") : Text("Show password"))
            }

            if model.passwordPromptIsRetry {
                Label("Incorrect password. Please try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    model.cancelPasswordPrompt()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("OK", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.submitPassword(password, settings: .current)
    }
}

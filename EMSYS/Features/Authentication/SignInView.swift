import SwiftUI

struct SignInView: View {
    @Environment(AuthenticationSession.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize {
                        HStack(alignment: .center, spacing: 64) {
                            welcome
                                .frame(maxWidth: 360, alignment: .leading)
                            signInPanel
                        }
                    } else {
                        VStack(alignment: .leading, spacing: AppStyle.Spacing.extraLarge) {
                            welcome
                            signInPanel
                        }
                        .frame(maxWidth: 420)
                    }
                }
                .padding(.horizontal, AppStyle.Spacing.large)
                .padding(.vertical, AppStyle.Spacing.extraLarge)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppStyle.Colors.surface)
        }
        .navigationTitle("")
        .onDisappear { password = "" }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            HStack(spacing: AppStyle.Spacing.medium) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(verbatim: "EMSYS")
                    .font(.title.bold())
                    .tracking(1)
            }
            Text("auth.welcome")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("auth.welcomeDescription")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signInPanel: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                Text("auth.signIn")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("auth.signInDescription")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    Text("auth.email").font(.subheadline.weight(.medium))
                    TextField("auth.email", text: $email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                        .modifier(SignInFieldStyle())
                }
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    Text("auth.password").font(.subheadline.weight(.medium))
                    SecureField("auth.password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { signIn() }
                        .modifier(SignInFieldStyle())
                }
            }
            .disabled(session.isSigningIn)

            if let issue = session.issue {
                Label {
                    Text(LocalizedStringKey(issue.rawValue))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityAddTraits(.updatesFrequently)
            }

            Button(action: signIn) {
                HStack(spacing: AppStyle.Spacing.small) {
                    if session.isSigningIn {
                        ProgressView().controlSize(.small)
                    }
                    Text(session.isSigningIn ? "auth.signingIn" : "auth.signIn")
                        .fontWeight(.semibold)
                    if !session.isSigningIn {
                        Image(systemName: "arrow.right")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)
        }
        .padding(AppStyle.Spacing.large)
        .frame(maxWidth: 420)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty && !session.isSigningIn
    }

    private func signIn() {
        guard canSubmit else { return }
        focusedField = nil
        let submittedPassword = password
        password = ""
        Task { await session.signIn(email: email, password: submittedPassword) }
    }
}

private struct SignInFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, AppStyle.Spacing.medium)
            .padding(.vertical, 14)
            .frame(minHeight: 48)
            .background(AppStyle.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
    }
}

#Preview {
    NavigationStack {
        SignInView().environment(AuthenticationSession())
    }
    .environment(\.locale, AppLanguage.dominicanSpanish.locale)
}

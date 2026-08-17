import AuthenticationServices
import SwiftUI

struct OnboardingFlowView: View {
    @State var model: OnboardingViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: model.progress)
                    .tint(.primary)
                    .padding(.horizontal, NeedsTheme.pageInset)
                    .opacity(model.step == .welcome ? 0 : 1)

                Group {
                    switch model.step {
                    case .welcome:
                        WelcomeStepView(onContinue: model.advance)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    case .account:
                        AccountStepView(model: model)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    case .address:
                        AddressStepView(model: model)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    case .reminder:
                        ReminderStepView(model: model)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .animation(.smooth, value: model.step)
            }
            .background(NeedsTheme.background)
            .toolbar {
                if model.step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: model.goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                    }
                }
            }
        }
    }
}

private struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.large) {
            Spacer()
            NeedsLogo()

            VStack(alignment: .leading, spacing: NeedsSpacing.small) {
                Text("onboarding.title")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("onboarding.title")
                Text("onboarding.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            PrimaryButton(title: "common.continue", action: onContinue)
                .accessibilityIdentifier("onboarding.continue")
        }
        .needsPage()
        .padding(.vertical, NeedsSpacing.xLarge)
    }
}

private struct AccountStepView: View {
    @Bindable var model: OnboardingViewModel
    @State private var appleNonce: AppleSignInNonce?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                OnboardingTitle(title: "Your account", detail: "Save your list and follow every order.")

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                    do {
                        let nonce = try AppleSignInNonce.generate()
                        appleNonce = nonce
                        request.nonce = nonce.sha256
                    } catch {
                        appleNonce = nil
                        model.errorMessage = "Secure sign-in couldn't be started. Please try again."
                    }
                } onCompletion: { result in
                    if case let .success(authorization) = result,
                       let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                       let identityToken = credential.identityToken,
                       let nonce = appleNonce {
                        appleNonce = nil
                        Task {
                            await model.acceptAppleCredential(
                                identityToken: identityToken,
                                authorizationCode: credential.authorizationCode,
                                rawNonce: nonce.rawValue,
                                givenName: credential.fullName?.givenName,
                                familyName: credential.fullName?.familyName
                            )
                        }
                    } else {
                        appleNonce = nil
                        model.errorMessage = "Apple sign-in couldn't be completed. You can try again or use email."
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
                .accessibilityIdentifier("account.apple")

                HStack {
                    Rectangle().fill(NeedsTheme.separator).frame(height: 1)
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    Rectangle().fill(NeedsTheme.separator).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: NeedsSpacing.small) {
                    TextField("Email", text: $model.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(NeedsSpacing.medium)
                        .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
                        .accessibilityIdentifier("account.email")

                    if model.hasRequestedCode {
                        TextField("6-digit code", text: $model.verificationCode)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .padding(NeedsSpacing.medium)
                            .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
                            .accessibilityIdentifier("account.code")
                    }
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("account.error")
                }

                PrimaryButton(
                    title: model.hasRequestedCode ? "common.continue" : "account.email",
                    isLoading: model.isWorking
                ) {
                    Task {
                        if model.hasRequestedCode {
                            await model.acceptEmailCode()
                        } else {
                            await model.sendCode()
                        }
                    }
                }
                .accessibilityIdentifier("account.email.continue")
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.xLarge)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct AddressStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NeedsSpacing.large) {
                OnboardingTitle(title: "Where should we deliver?", detail: "You can update this anytime in Settings.")

                VStack(spacing: NeedsSpacing.small) {
                    AddressField("Street", text: $model.street, contentType: .streetAddressLine1)
                    AddressField("Apartment (optional)", text: $model.apartment, contentType: .streetAddressLine2)
                    AddressField("City", text: $model.city, contentType: .addressCity)
                    HStack(spacing: NeedsSpacing.small) {
                        AddressField("ZIP code", text: $model.postalCode, contentType: .postalCode)
                            .keyboardType(.numbersAndPunctuation)
                        AddressField("State", text: $model.region, contentType: .addressState)
                            .frame(maxWidth: 130)
                    }
                    AddressField("Country", text: $model.country, contentType: .countryName)
                }

                PrimaryButton(title: "common.continue", isDisabled: !model.addressIsValid, action: model.advance)
                    .accessibilityIdentifier("address.continue")
            }
            .needsPage()
            .padding(.vertical, NeedsSpacing.xLarge)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct ReminderStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.large) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 42, weight: .medium))
                .accessibilityHidden(true)
            OnboardingTitle(title: "A helpful reminder", detail: "We can remind you when your list is ready.")

            VStack(spacing: NeedsSpacing.medium) {
                Toggle("Daily reminder", isOn: $model.reminderEnabled)
                    .fontWeight(.semibold)
                if model.reminderEnabled {
                    DatePicker("Reminder time", selection: $model.reminderTime, displayedComponents: .hourAndMinute)
                    HStack {
                        Text("Time zone")
                        Spacer()
                        Text(TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                }
            }
            .needsCard()

            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()
            PrimaryButton(
                title: model.reminderEnabled ? "notifications.allow" : "common.continue",
                isLoading: model.isWorking
            ) {
                Task { await model.finish() }
            }
            .accessibilityIdentifier("reminder.continue")
        }
        .needsPage()
        .padding(.vertical, NeedsSpacing.xLarge)
    }
}

private struct OnboardingTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: NeedsSpacing.small) {
            Text(title)
                .font(.largeTitle.bold())
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddressField: View {
    let title: String
    @Binding var text: String
    let contentType: UITextContentType?

    init(_ title: String, text: Binding<String>, contentType: UITextContentType?) {
        self.title = title
        _text = text
        self.contentType = contentType
    }

    var body: some View {
        TextField(title, text: $text)
            .textContentType(contentType)
            .padding(NeedsSpacing.medium)
            .background(NeedsTheme.surface, in: RoundedRectangle(cornerRadius: NeedsTheme.controlRadius, style: .continuous))
            .accessibilityIdentifier("address.\(title.lowercased().replacingOccurrences(of: " ", with: "."))")
    }
}

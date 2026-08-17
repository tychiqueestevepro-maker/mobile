import StoreKit
import SwiftUI

struct SettingsView: View {
    @State var model: SettingsViewModel
    @State private var confirmReset = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            profileSection
            deliverySection
            preferenceSection
            membershipSection
            legalSection
            accountSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("settings.title")
        .navigationBarTitleDisplayMode(.large)
        .task { await model.load() }
        .alert("Reset learned preferences?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { Task { await model.resetPreferences() } }
        } message: {
            Text("settings.reset_message")
        }
        .alert("Delete account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) { Task { await model.deleteAccount() } }
        } message: {
            Text("This permanently removes your account, current list, orders, and learned preferences.")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .padding(NeedsSpacing.small)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, NeedsSpacing.small)
                    .accessibilityIdentifier("settings.error")
            }
        }
    }

    private var profileSection: some View {
        Section("Account") {
            LabeledContent("Name", value: model.profile.name)
            LabeledContent("Email", value: model.profile.email)
        }
    }

    private var deliverySection: some View {
        Section("Delivery") {
            NavigationLink {
                AddressSummaryView(address: model.address)
            } label: {
                LabeledContent("Default address", value: model.address.street)
            }

            Toggle("Daily reminder", isOn: Binding(
                get: { model.notificationPreferences.isDailyReminderEnabled },
                set: { value in
                    model.notificationPreferences.isDailyReminderEnabled = value
                    Task { await model.saveReminder() }
                }
            ))
            .accessibilityIdentifier("settings.reminder.toggle")

            if model.notificationPreferences.isDailyReminderEnabled {
                DatePicker(
                    "Reminder time",
                    selection: Binding(
                        get: { model.reminderTime },
                        set: { value in
                            model.reminderTime = value
                            Task { await model.saveReminder() }
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("settings.reminder.time")

                NavigationLink {
                    TimeZonePickerView(selection: Binding(
                        get: { model.notificationPreferences.timeZoneIdentifier },
                        set: { identifier in
                            model.notificationPreferences.timeZoneIdentifier = identifier
                            Task { await model.saveReminder() }
                        }
                    ))
                } label: {
                    LabeledContent("Time zone", value: model.notificationPreferences.timeZoneIdentifier)
                        .font(.footnote)
                }
                .accessibilityIdentifier("settings.reminder.timezone")
            }
        }
    }

    @ViewBuilder
    private var preferenceSection: some View {
        Section {
            switch model.learnedPreferences {
            case .idle, .loading:
                HStack { ProgressView(); Text("Loading preferences...") }
            case .empty:
                Text("Your confirmed choices will gradually shape the three options you see. Current intent always comes first.")
                    .foregroundStyle(.secondary)
            case let .loaded(summary), let .offline(.some(summary)):
                if !summary.entries.isEmpty {
                    ForEach(summary.entries.sorted { abs($0.score) > abs($1.score) }.prefix(12)) { preference in
                        LearnedPreferenceRow(preference: preference) {
                            Task { await model.removePreference(preference) }
                        }
                    }
                }
                ForEach(summary.acceptedPricesByCategory.keys.sorted(), id: \.self) { category in
                    if let price = summary.acceptedPricesByCategory[category] {
                        TypicalPriceRow(category: category, profile: price)
                    }
                }
                Button("Reset learned preferences", role: .destructive) { confirmReset = true }
                    .disabled(model.isResetting)
                    .accessibilityIdentifier("settings.preferences.reset")
            case .offline(.none):
                Text("Connect to review learned preferences.")
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Learned preferences")
        } footer: {
            Text("Your recent request always matters most. Preferences help rank strong matches without limiting discovery.")
        }
    }

    private var membershipSection: some View {
        Section("Membership") {
            if model.isPlus {
                LabeledContent("Plan", value: "Plus")
                Button("Manage subscription") {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            try? await AppStore.showManageSubscriptions(in: scene)
                        }
                    }
                }
            } else {
                Button(action: model.openPlus) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upgrade to Plus").fontWeight(.semibold)
                            Text("Smarter totals across your whole list")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("settings.plus")
            }
        }
    }

    private var legalSection: some View {
        Section("Legal") {
            NavigationLink("Terms") { LegalTextView(title: "Terms") }
            NavigationLink("Privacy") { LegalTextView(title: "Privacy") }
        }
    }

    private var accountSection: some View {
        Section {
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            Button("Delete account", role: .destructive) { confirmDelete = true }
                .accessibilityIdentifier("settings.delete_account")
        }
    }
}

private struct LearnedPreferenceRow: View {
    let preference: LearnedPreference
    let remove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NeedsSpacing.xSmall) {
                    Text(preference.value).fontWeight(.semibold)
                    Text(preference.score >= 0 ? "Preferred" : "Less preferred")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(NeedsTheme.surface, in: Capsule())
                }
                Text("\(preference.category.replacingOccurrences(of: "_", with: " ").capitalized) · \(preference.dimension.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(preference.value) preference")
        }
    }
}

private struct TypicalPriceRow: View {
    let category: String
    let profile: AcceptedPriceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Typical price")
                    .fontWeight(.semibold)
                Spacer()
                Text(CurrencyFormatter.string(amount: profile.median, currency: profile.currency))
                    .monospacedDigit()
            }
            Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Usually \(CurrencyFormatter.string(amount: profile.lowerBound, currency: profile.currency))–\(CurrencyFormatter.string(amount: profile.upperBound, currency: profile.currency)) · \(profile.positiveSignalCount) confirmed choices")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AddressSummaryView: View {
    let address: Address

    var body: some View {
        Form {
            LabeledContent("Street", value: address.street)
            if let apartment = address.apartment, !apartment.isEmpty {
                LabeledContent("Apartment", value: apartment)
            }
            LabeledContent("City", value: address.city)
            LabeledContent("State", value: address.region)
            LabeledContent("ZIP code", value: address.postalCode)
            LabeledContent("Country", value: address.country)
        }
        .navigationTitle("Default address")
    }
}

private struct LegalTextView: View {
    let title: String

    var body: some View {
        ScrollView {
            Text("The complete \(title.lowercased()) will be provided before release. This development build does not process real purchases or deliveries.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .needsPage()
                .padding(.vertical, NeedsSpacing.large)
        }
        .navigationTitle(title)
    }
}

private struct TimeZonePickerView: View {
    @Binding var selection: String
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var identifiers: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List(identifiers, id: \.self) { identifier in
            Button {
                selection = identifier
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identifier.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.primary)
                        if let zone = TimeZone(identifier: identifier) {
                            Text(zone.localizedName(for: .standard, locale: .current) ?? identifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if identifier == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "City or region")
    }
}

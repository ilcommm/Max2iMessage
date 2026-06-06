import Contacts
import SwiftUI

struct ContactEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let value: String
    let kind: String
}

struct ContactListSheet: View {
    @Binding var recipient: String
    @Binding var contactIdentifier: String?
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ContactEntry] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var filteredEntries: [ContactEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(query) ||
            $0.value.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Выберите контакт")
                    .font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            .padding()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            TextField("Поиск", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if isLoading {
                ProgressView("Загрузка контактов…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView("Контакты не найдены", systemImage: "person.crop.circle")
            } else {
                List(filteredEntries) { entry in
                    Button {
                        recipient = entry.value
                        contactIdentifier = entry.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.body)
                            Text("\(entry.kind): \(entry.value)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .task { await loadContacts() }
    }

    private func loadContacts() async {
        isLoading = true
        defer { isLoading = false }

        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            guard granted else {
                errorMessage = "Нет доступа к контактам"
                return
            }
        } else if status != .authorized {
            errorMessage = "Разрешите доступ к контактам в Системных настройках → Конфиденциальность"
            return
        }

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Self.fetchContactEntries()
            }.value
            entries = loaded
        } catch {
            errorMessage = error.localizedDescription
            LogService.shared.log(.error, message: "Contacts load failed: \(error.localizedDescription)", level: "ERROR")
        }
    }

    nonisolated private static func fetchContactEntries() throws -> [ContactEntry] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        var loaded: [ContactEntry] = []

        try store.enumerateContacts(with: request) { contact, _ in
            let formattedName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let name: String
            if !formattedName.isEmpty {
                name = formattedName
            } else if !contact.givenName.isEmpty {
                name = contact.givenName
            } else {
                name = "Без имени"
            }

            for phone in contact.phoneNumbers {
                let value = phone.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                loaded.append(ContactEntry(
                    id: contact.identifier,
                    name: name,
                    value: value,
                    kind: "Телефон"
                ))
            }

            for email in contact.emailAddresses {
                let value = (email.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                loaded.append(ContactEntry(
                    id: contact.identifier,
                    name: name,
                    value: value,
                    kind: "Email"
                ))
            }
        }

        return loaded
    }
}

struct ContactPickerButton: View {
    @Binding var recipient: String
    @Binding var contactIdentifier: String?
    @State private var showSheet = false

    var body: some View {
        Button("Выбрать из контактов") {
            showSheet = true
        }
        .sheet(isPresented: $showSheet) {
            ContactListSheet(recipient: $recipient, contactIdentifier: $contactIdentifier)
        }
    }
}

import Foundation
import Supabase

public actor InMemoryAddressService: AddressService {
    private var addressesByUser: [UUID: Address]

    public init(seed: [UUID: Address] = [:]) {
        addressesByUser = seed
    }

    public func defaultAddress(for userID: UUID) async throws -> Address? {
        addressesByUser[userID]
    }

    public func saveDefaultAddress(
        _ address: Address,
        userID: UUID,
        recipientName: String
    ) async throws -> Address {
        addressesByUser[userID] = address
        return address
    }
}

public actor SupabaseAddressService: AddressService {
    private struct Row: Decodable, Sendable {
        let id: UUID
        let line1: String
        let line2: String?
        let city: String
        let region: String
        let postal_code: String
        let country_code: String
        let is_default: Bool
    }

    private struct InsertInput: Encodable, Sendable {
        let id: UUID
        let user_id: UUID
        let label: String
        let recipient_name: String
        let line1: String
        let line2: String?
        let city: String
        let region: String
        let postal_code: String
        let country_code: String
        let is_default: Bool
    }

    private struct UpdateInput: Encodable, Sendable {
        let recipient_name: String
        let line1: String
        let line2: String?
        let city: String
        let region: String
        let postal_code: String
        let country_code: String
        let is_default: Bool
    }

    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func defaultAddress(for userID: UUID) async throws -> Address? {
        let rows: [Row] = try await client.from("addresses")
            .select("id,line1,line2,city,region,postal_code,country_code,is_default")
            .eq("user_id", value: userID)
            .eq("is_default", value: true)
            .limit(1)
            .execute()
            .value
        return rows.first.map(map)
    }

    public func saveDefaultAddress(
        _ address: Address,
        userID: UUID,
        recipientName: String
    ) async throws -> Address {
        let cleanName = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              !address.street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !address.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !address.postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidInput("A recipient and complete delivery address are required")
        }

        if let existing = try await existingDefaultRow(for: userID) {
            let rows: [Row] = try await client.from("addresses")
                .update(UpdateInput(
                    recipient_name: cleanName,
                    line1: address.street,
                    line2: address.apartment,
                    city: address.city,
                    region: address.region,
                    postal_code: address.postalCode,
                    country_code: address.country.uppercased(),
                    is_default: true
                ))
                .eq("id", value: existing.id)
                .select("id,line1,line2,city,region,postal_code,country_code,is_default")
                .execute()
                .value
            guard let row = rows.first else { throw AppError.notFound }
            return map(row)
        }

        let rows: [Row] = try await client.from("addresses")
            .insert(InsertInput(
                id: address.id,
                user_id: userID,
                label: "Home",
                recipient_name: cleanName,
                line1: address.street,
                line2: address.apartment,
                city: address.city,
                region: address.region,
                postal_code: address.postalCode,
                country_code: address.country.uppercased(),
                is_default: true
            ))
            .select("id,line1,line2,city,region,postal_code,country_code,is_default")
            .execute()
            .value
        guard let row = rows.first else { throw AppError.notFound }
        return map(row)
    }

    private func existingDefaultRow(for userID: UUID) async throws -> Row? {
        let rows: [Row] = try await client.from("addresses")
            .select("id,line1,line2,city,region,postal_code,country_code,is_default")
            .eq("user_id", value: userID)
            .eq("is_default", value: true)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private func map(_ row: Row) -> Address {
        Address(
            id: row.id,
            street: row.line1,
            apartment: row.line2,
            city: row.city,
            postalCode: row.postal_code,
            region: row.region,
            country: row.country_code,
            isDefault: row.is_default
        )
    }
}

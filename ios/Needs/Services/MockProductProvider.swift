import Foundation

public actor MockProductProvider: ProductProvider {
    public let retailers: [Retailer]
    private let catalog: [ProductCandidate]

    public init() {
        self.retailers = MockCatalog.retailers
        self.catalog = MockCatalog.products
    }

    public init(retailers: [Retailer], products: [ProductCandidate]) {
        self.retailers = retailers
        self.catalog = products
    }

    public func searchProducts(for intent: NeedIntent, limit: Int = 3) async throws -> [ProductCandidate] {
        guard limit > 0 else { return [] }
        return catalog
            .filter { $0.category == intent.category }
            .map { score($0, for: intent) }
            .sorted { lhs, rhs in
                if lhs.isExplicitlyIncompatible != rhs.isExplicitlyIncompatible {
                    return !lhs.isExplicitlyIncompatible
                }
                if lhs.matchTier != rhs.matchTier { return lhs.matchTier > rhs.matchTier }
                if lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }
                if lhs.price != rhs.price { return lhs.price < rhs.price }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(min(limit, 3))
            .map { $0 }
    }

    public func getProduct(id: UUID) async throws -> ProductCandidate? {
        catalog.first { $0.id == id }
    }

    public func checkAvailability(productIDs: [UUID]) async throws -> [UUID: ProductAvailability] {
        Dictionary(uniqueKeysWithValues: catalog
            .filter { productIDs.contains($0.id) }
            .map { ($0.id, $0.availability) })
    }

    private func score(_ product: ProductCandidate, for intent: NeedIntent) -> ProductCandidate {
        var result = product
        var score = 0.70
        var matched = 0
        var incompatible = false

        for (key, requestedValue) in intent.attributes {
            guard let candidateValue = product.attributes[key] else { continue }
            if candidateValue.caseInsensitiveCompare(requestedValue) == .orderedSame {
                matched += 1
                score += 0.075
            } else if ["size", "color", "battery_size", "fat"].contains(key) {
                incompatible = true
                score -= 0.2
            }
        }

        if product.availability == .lowStock { score -= 0.02 }
        if product.availability == .unavailable { score = 0 }
        result.matchScore = min(max(score, 0), 1)
        result.isExplicitlyIncompatible = incompatible
        if incompatible { result.matchTier = .fallback }
        else if !intent.attributes.isEmpty && matched == intent.attributes.count { result.matchTier = .exact }
        else if matched > 0 || intent.attributes.isEmpty { result.matchTier = .strong }
        else { result.matchTier = .partial }
        return result
    }
}

public enum MockCatalog {
    public static let storeAID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    public static let storeBID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    public static let storeCID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

    public static let retailers: [Retailer] = [
        Retailer(id: storeAID, name: "Market Street Goods", deliveryFee: 7, serviceFee: 2),
        Retailer(id: storeBID, name: "Bay Pantry", deliveryFee: 6, serviceFee: 2.50),
        Retailer(id: storeCID, name: "Mission Essentials", deliveryFee: 5, serviceFee: 3)
    ]

    private struct Row {
        let category: String
        let name: String
        let brand: String
        let description: String
        let price: Decimal
        let size: String
        let unit: String
        let store: UUID
        let attributes: [String: String]
        let availability: ProductAvailability
    }

    private static let rows: [Row] = [
        .init(category: "trash_bags", name: "ForceFlex Large Trash Bags", brand: "Glad", description: "Strong and flexible drawstring bags", price: 12.49, size: "30", unit: "bags", store: storeAID, attributes: ["size": "large", "color": "black", "durability": "high"], availability: .inStock),
        .init(category: "trash_bags", name: "Ultra Strong Trash Bags", brand: "Hefty", description: "Leak protection and odor control", price: 10.99, size: "28", unit: "bags", store: storeBID, attributes: ["size": "large", "color": "black", "durability": "high"], availability: .inStock),
        .init(category: "trash_bags", name: "Tall Kitchen Drawstring Bags", brand: "GoodHome", description: "Everyday dependable kitchen bags", price: 7.49, size: "40", unit: "bags", store: storeCID, attributes: ["size": "large", "color": "white", "durability": "standard"], availability: .inStock),
        .init(category: "toothpaste", name: "Pronamel Gentle Whitening", brand: "Sensodyne", description: "Daily enamel and sensitivity protection", price: 7.49, size: "4", unit: "oz", store: storeAID, attributes: ["benefit": "sensitivity", "flavor": "mint"], availability: .inStock),
        .init(category: "toothpaste", name: "Total Whitening Toothpaste", brand: "Colgate", description: "Whole-mouth clean with whitening", price: 5.99, size: "5.1", unit: "oz", store: storeBID, attributes: ["benefit": "whitening", "flavor": "mint"], availability: .inStock),
        .init(category: "toothpaste", name: "Pro-Health Clean Mint", brand: "Crest", description: "Everyday cavity and gum protection", price: 4.99, size: "4.6", unit: "oz", store: storeCID, attributes: ["benefit": "complete", "flavor": "mint"], availability: .inStock),
        .init(category: "toilet_paper", name: "Ultra Soft Bath Tissue", brand: "Charmin", description: "Soft two-ply bath tissue", price: 14.99, size: "12", unit: "rolls", store: storeAID, attributes: ["ply": "2", "feel": "soft"], availability: .inStock),
        .init(category: "toilet_paper", name: "Comfort Plus", brand: "Cottonelle", description: "Cushioned cleaning ripples", price: 12.49, size: "12", unit: "rolls", store: storeBID, attributes: ["ply": "2", "feel": "soft"], availability: .lowStock),
        .init(category: "toilet_paper", name: "Everyday Bath Tissue", brand: "GoodHome", description: "Reliable septic-safe tissue", price: 8.99, size: "12", unit: "rolls", store: storeCID, attributes: ["ply": "2", "feel": "standard"], availability: .inStock),
        .init(category: "eggs", name: "Organic Large Brown Eggs", brand: "Happy Hen", description: "Certified organic cage-free eggs", price: 6.49, size: "12", unit: "eggs", store: storeAID, attributes: ["organic": "true", "grade": "A"], availability: .inStock),
        .init(category: "eggs", name: "Large Grade A Eggs", brand: "Bay Farms", description: "Fresh large white eggs", price: 4.99, size: "12", unit: "eggs", store: storeBID, attributes: ["organic": "false", "grade": "A"], availability: .inStock),
        .init(category: "eggs", name: "Pasture Raised Large Eggs", brand: "Sunrise", description: "Pasture raised brown eggs", price: 7.99, size: "12", unit: "eggs", store: storeCID, attributes: ["organic": "true", "grade": "AA"], availability: .inStock),
        .init(category: "milk", name: "Organic Whole Milk", brand: "Horizon", description: "USDA organic whole milk", price: 6.29, size: "0.5", unit: "gal", store: storeAID, attributes: ["fat": "whole", "organic": "true"], availability: .inStock),
        .init(category: "milk", name: "2% Reduced Fat Milk", brand: "Bay Dairy", description: "Local reduced-fat milk", price: 4.49, size: "1", unit: "gal", store: storeBID, attributes: ["fat": "2_percent", "organic": "false"], availability: .inStock),
        .init(category: "milk", name: "Whole Milk", brand: "Clover", description: "Fresh whole milk", price: 5.39, size: "1", unit: "gal", store: storeCID, attributes: ["fat": "whole", "organic": "false"], availability: .inStock),
        .init(category: "bottled_water", name: "Purified Water", brand: "Aquafina", description: "Purified bottled water", price: 6.99, size: "24", unit: "bottles", store: storeAID, attributes: ["water": "purified"], availability: .inStock),
        .init(category: "bottled_water", name: "Spring Water", brand: "Crystal Geyser", description: "Natural alpine spring water", price: 5.99, size: "24", unit: "bottles", store: storeBID, attributes: ["water": "spring"], availability: .inStock),
        .init(category: "bottled_water", name: "Still Mineral Water", brand: "Acqua Panna", description: "Smooth mineral water", price: 8.49, size: "6", unit: "bottles", store: storeCID, attributes: ["water": "mineral"], availability: .lowStock),
        .init(category: "paper_towels", name: "Select-a-Size", brand: "Bounty", description: "Absorbent two-ply paper towels", price: 13.99, size: "6", unit: "rolls", store: storeAID, attributes: ["absorbency": "high"], availability: .inStock),
        .init(category: "paper_towels", name: "Tear-a-Square", brand: "Sparkle", description: "Flexible sheet sizes", price: 9.49, size: "6", unit: "rolls", store: storeBID, attributes: ["absorbency": "standard"], availability: .inStock),
        .init(category: "paper_towels", name: "Recycled Paper Towels", brand: "Seventh Generation", description: "Made with recycled paper", price: 11.99, size: "6", unit: "rolls", store: storeCID, attributes: ["material": "recycled"], availability: .inStock),
        .init(category: "dish_soap", name: "Ultra Dish Liquid", brand: "Dawn", description: "Powerful grease cleaning", price: 5.49, size: "18", unit: "fl oz", store: storeAID, attributes: ["scent": "fresh", "strength": "high"], availability: .inStock),
        .init(category: "dish_soap", name: "Free + Clear Dish Soap", brand: "Seventh Generation", description: "Fragrance-free plant-based soap", price: 4.99, size: "19", unit: "fl oz", store: storeBID, attributes: ["scent": "none", "plant_based": "true"], availability: .inStock),
        .init(category: "dish_soap", name: "Lemon Dish Liquid", brand: "Palmolive", description: "Fresh lemon grease cleaning", price: 3.99, size: "20", unit: "fl oz", store: storeCID, attributes: ["scent": "lemon", "strength": "standard"], availability: .inStock),
        .init(category: "laundry_detergent", name: "Hygienic Clean Liquid", brand: "Tide", description: "Deep cleaning liquid detergent", price: 15.99, size: "69", unit: "fl oz", store: storeAID, attributes: ["format": "liquid", "scent": "original"], availability: .inStock),
        .init(category: "laundry_detergent", name: "Free Clear Detergent", brand: "All", description: "Unscented sensitive-skin formula", price: 12.99, size: "88", unit: "fl oz", store: storeBID, attributes: ["format": "liquid", "scent": "none"], availability: .inStock),
        .init(category: "laundry_detergent", name: "Laundry Detergent Packs", brand: "Dropps", description: "Premeasured detergent pods", price: 14.49, size: "32", unit: "loads", store: storeCID, attributes: ["format": "pods", "scent": "fresh"], availability: .inStock),
        .init(category: "shampoo", name: "Daily Moisture Renewal", brand: "Pantene", description: "Moisturizing daily shampoo", price: 7.99, size: "17.9", unit: "fl oz", store: storeAID, attributes: ["benefit": "moisture"], availability: .inStock),
        .init(category: "shampoo", name: "Daily Hydration Shampoo", brand: "SheaMoisture", description: "Hydrating coconut shampoo", price: 11.99, size: "13", unit: "fl oz", store: storeBID, attributes: ["benefit": "hydration"], availability: .inStock),
        .init(category: "shampoo", name: "Classic Clean Shampoo", brand: "Head & Shoulders", description: "Everyday dandruff care", price: 8.49, size: "13.5", unit: "fl oz", store: storeCID, attributes: ["benefit": "dandruff"], availability: .inStock),
        .init(category: "batteries", name: "MAX AA Batteries", brand: "Energizer", description: "Long-lasting alkaline power", price: 12.99, size: "16", unit: "count", store: storeAID, attributes: ["battery_size": "AA", "chemistry": "alkaline"], availability: .inStock),
        .init(category: "batteries", name: "Coppertop AAA Batteries", brand: "Duracell", description: "Reliable alkaline batteries", price: 11.99, size: "16", unit: "count", store: storeBID, attributes: ["battery_size": "AAA", "chemistry": "alkaline"], availability: .inStock),
        .init(category: "batteries", name: "Rechargeable AA Batteries", brand: "Panasonic", description: "Reusable rechargeable cells", price: 16.99, size: "8", unit: "count", store: storeCID, attributes: ["battery_size": "AA", "chemistry": "rechargeable"], availability: .inStock),
        .init(category: "pasta", name: "Spaghetti No. 5", brand: "Barilla", description: "Classic durum wheat spaghetti", price: 2.49, size: "16", unit: "oz", store: storeAID, attributes: ["shape": "spaghetti"], availability: .inStock),
        .init(category: "pasta", name: "Organic Penne Rigate", brand: "DeLallo", description: "Organic bronze-cut penne", price: 4.99, size: "16", unit: "oz", store: storeBID, attributes: ["shape": "penne", "organic": "true"], availability: .inStock),
        .init(category: "pasta", name: "Protein+ Rotini", brand: "Barilla", description: "Protein-enriched rotini", price: 3.99, size: "14.5", unit: "oz", store: storeCID, attributes: ["shape": "rotini", "protein": "high"], availability: .inStock),
        .init(category: "coffee", name: "Pike Place Roast", brand: "Starbucks", description: "Medium roast whole bean coffee", price: 12.99, size: "12", unit: "oz", store: storeAID, attributes: ["roast": "medium", "format": "whole_bean"], availability: .inStock),
        .init(category: "coffee", name: "Major Dickason's Blend", brand: "Peet's", description: "Rich dark roast ground coffee", price: 11.49, size: "10.5", unit: "oz", store: storeBID, attributes: ["roast": "dark", "format": "ground"], availability: .inStock),
        .init(category: "coffee", name: "Breakfast Blend", brand: "Green Mountain", description: "Light roast coffee pods", price: 10.99, size: "12", unit: "pods", store: storeCID, attributes: ["roast": "light", "format": "pods"], availability: .inStock)
    ]

    public static let products: [ProductCandidate] = rows.enumerated().map { index, row in
        let retailer = retailers.first(where: { $0.id == row.store })!
        return ProductCandidate(
            id: deterministicID(index + 1),
            storeID: row.store,
            retailerName: retailer.name,
            name: row.name,
            brand: row.brand,
            category: row.category,
            description: row.description,
            price: row.price,
            size: row.size,
            unit: row.unit,
            attributes: row.attributes,
            availability: row.availability
        )
    }

    private static func deterministicID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!
    }
}

//
//  CountryNormalizer.swift
//  JobList
//

import Foundation
import Synchronization

/// Turns free-form location text such as `"Remote (US)"`, `"Austin, TX 78701"`, or
/// `"London SW1A 1AA"` into canonical English country names.
///
/// Resolution order for each location segment:
/// 1. The whole segment is a country name, alias, or (in the `countries` field) an ISO code.
/// 2. A state/province followed by a postal code that is valid for it (US, Canada, Australia,
///    India), or a full UK postcode.
/// 3. A comma-separated part is a country name, scanning from the end.
/// 4. A country name appears anywhere in the segment, skipping state names so that
///    "New Mexico" or "New Jersey" aren't read as Mexico or Jersey.
///
/// Text that names no country ("Remote", "Worldwide", "San Francisco, CA") yields nothing.
nonisolated enum CountryNormalizer {

    /// Canonical country names for a job, from its `countries` field, falling back to
    /// `rawLocation` when that field has nothing usable.
    static func countries(from values: [String], rawLocation: String) -> [String] {
        var result: [String] = []
        func add(_ names: [String]) {
            for name in names where !result.contains(name) { result.append(name) }
        }
        for value in values { add(countries(in: value, isCountryField: true)) }
        if result.isEmpty { add(countries(in: rawLocation, isCountryField: false)) }
        return result
    }

    /// Location strings repeat heavily across a file, so results are memoized.
    private static let cache = Mutex<[CacheKey: [String]]>([:])

    private struct CacheKey: Hashable {
        let text: String
        let isCountryField: Bool
    }

    static func countries(in text: String, isCountryField: Bool) -> [String] {
        if text.isEmpty { return [] }
        let cacheKey = CacheKey(text: text, isCountryField: isCountryField)
        if let cached = cache.withLock({ $0[cacheKey] }) { return cached }

        // Fold diacritics once here; everything below works on the folded text.
        let text = fold(text)
        var result: [String] = []
        if let code = exactMatch(text, allowISOCode: isCountryField) {
            result = [displayName(code)]
        } else {
            for segment in segments(of: text) {
                if let code = resolve(segment, allowISOCode: isCountryField) {
                    let name = displayName(code)
                    if !result.contains(name) { result.append(name) }
                }
            }
        }
        cache.withLock { $0[cacheKey] = result }
        return result
    }

    // MARK: Segment resolution

    private static func resolve(_ segment: String, allowISOCode: Bool) -> String? {
        if let code = exactMatch(segment, allowISOCode: allowISOCode) { return code }

        let tokens = words(segment)
        if let code = postalMatch(tokens) { return code }

        let parts = segment.split(separator: ",").map(String.init).filter { !words($0).isEmpty }
        // A spelled-out state such as "California" or "Brisbane, California" identifies its
        // country without a postal code, unless the name is ambiguous (e.g. Georgia).
        if let last = parts.last, let code = Tables.shared.subdivisionNameCountries[Tables.key(words(last))] {
            return code
        }
        // "Lebanon, PA" or "Toronto, ON": the trailing state means the earlier parts are
        // cities, and without a postal code the country isn't certain.
        if let last = parts.last, parts.count > 1, isSubdivision(last) { return nil }
        for part in parts.reversed() {
            if let code = exactMatch(part, allowISOCode: false) { return code }
        }
        return scan(tokens)
    }

    /// Splits on separators between distinct locations; parenthesized text becomes its own segment.
    private static func segments(of text: String) -> [String] {
        var outside = ""
        var segments: [String] = []
        var inner = ""
        var depth = 0
        for ch in text {
            switch ch {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth = max(0, depth - 1)
                if depth == 0 { segments.append(inner); inner = "" }
            default:
                if depth > 0 { inner.append(ch) } else { outside.append(ch) }
            }
        }
        if !inner.isEmpty { segments.append(inner) }

        let separators: Set<Character> = [";", "|", "/", "•", "\n", "·"]
        var pieces = outside.split(whereSeparator: { separators.contains($0) }).map(String.init)
        // " - " and " – " separate phrases ("Remote - US"); hyphens inside names are kept.
        pieces = pieces.flatMap { $0.components(separatedBy: " - ") }
        pieces = pieces.flatMap { $0.components(separatedBy: " – ") }
        return (pieces + segments).filter { !words($0).isEmpty }
    }

    private static func exactMatch(_ text: String, allowISOCode: Bool) -> String? {
        let tokens = words(text)
        guard !tokens.isEmpty else { return nil }
        let key = Tables.key(tokens)
        if let code = Tables.shared.countryNames[key] { return code }
        if tokens.count == 1, let original = tokens.first, original == original.uppercased() {
            if let code = Tables.shared.uppercaseAliases[original] { return code }
            // Skip codes that double as state abbreviations ("CO", "PA", "IN").
            if allowISOCode, original.count == 2, Tables.shared.isoCodes.contains(original),
               Tables.shared.subdivisions[original.lowercased()] == nil {
                return original
            }
        }
        return nil
    }

    /// Finds the longest country name anywhere in the tokens, skipping over state names.
    private static func scan(_ tokens: [String]) -> String? {
        let tables = Tables.shared
        let lowered = tokens.map { $0.lowercased() }
        var start = 0
        outer: while start < tokens.count {
            let longest = tables.multiWordStarts.contains(lowered[start]) ? min(6, tokens.count - start) : 1
            for length in stride(from: longest, through: 1, by: -1) {
                let key = lowered[start..<start + length].joined(separator: " ")
                if tables.blockedNames.contains(key) {
                    start += length
                    continue outer
                }
                if let code = tables.countryNames[key] { return code }
                if length == 1, let code = tables.uppercaseAliases[tokens[start]] { return code }
            }
            start += 1
        }
        return nil
    }

    /// Looks for a state/province (code or name) immediately followed by a postal code valid for it.
    private static func postalMatch(_ tokens: [String]) -> String? {
        // Every supported postal code contains a digit; most location text has none.
        guard tokens.contains(where: { $0.contains(where: \.isASCIIDigit) }) else { return nil }
        let tables = Tables.shared
        let lowered = tokens.map { $0.lowercased() }
        for start in tokens.indices {
            let longest = tables.multiWordStarts.contains(lowered[start]) ? min(4, tokens.count - start) : 1
            for length in 1...longest {
                let end = start + length
                guard end < tokens.count,
                      let subdivisions = tables.subdivisions[lowered[start..<end].joined(separator: " ")]
                else { continue }
                let following = Array(tokens[end...])
                for subdivision in subdivisions where subdivision.postalRule.accepts(following) {
                    return subdivision.countryCode
                }
            }
        }
        // UK postcodes (e.g. "SW1A 1AA") are distinctive enough on their own.
        for index in tokens.indices.dropLast() where isUKOutward(tokens[index]) && isUKInward(tokens[index + 1]) {
            return "GB"
        }
        return nil
    }

    private static func isSubdivision(_ text: String) -> Bool {
        let tokens = words(text)
        guard !tokens.isEmpty else { return false }
        let key = Tables.key(tokens)
        guard let subdivisions = Tables.shared.subdivisions[key] else { return false }
        // Codes only count when written in capitals ("PA", not "pa").
        return subdivisions.contains { !$0.isCode } || tokens.joined() == tokens.joined().uppercased()
    }

    // MARK: Text helpers

    /// Removes diacritics and full-width forms, preserving case.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Words with punctuation removed, case preserved. Periods and apostrophes are dropped
    /// inside words so "U.S.A." becomes "USA" and "d’Ivoire" becomes "dIvoire".
    /// Expects text already passed through `fold(_:)`.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in text {
            if ch.isWordCharacter {
                current.append(ch)
            } else if ch == "." || ch == "'" || ch == "’" {
                continue
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // Postal formats are checked byte by byte; regex literals are recompiled on each call,
    // which dominated load time.

    /// The outward half of a UK postcode: `A9`, `A99`, `AA9`, `AA99`, `A9A`, or `AA9A`.
    private static func isUKOutward(_ token: String) -> Bool {
        let b = Array(token.utf8)
        guard (2...4).contains(b.count), b[0].isUpperASCII else { return false }
        let digitIndex = b[1].isUpperASCII ? 2 : 1
        guard digitIndex < b.count, b[digitIndex].isDigitASCII else { return false }
        let rest = b[(digitIndex + 1)...]
        return rest.count <= 1 && rest.allSatisfy { $0.isUpperASCII || $0.isDigitASCII }
    }

    /// The inward half of a UK postcode: `9AA`.
    private static func isUKInward(_ token: String) -> Bool {
        let b = Array(token.utf8)
        return b.count == 3 && b[0].isDigitASCII && b[1].isUpperASCII && b[2].isUpperASCII
    }

    /// A Canadian forward sortation area (`A9A`) or full postal code (`A9A9A9`).
    fileprivate static func isCanadianPostalCode(_ token: String) -> Bool {
        let b = Array(token.utf8)
        guard b.count == 3 || b.count == 6 else { return false }
        return b.indices.allSatisfy { $0.isMultiple(of: 2) ? b[$0].isUpperASCII : b[$0].isDigitASCII }
    }

    private static func displayName(_ code: String) -> String {
        Tables.shared.displayNames[code] ?? code
    }
}

// MARK: - Lookup tables

private nonisolated struct Subdivision: Sendable {
    let countryCode: String
    let isCode: Bool
    let postalRule: PostalRule
}

/// Checks that the tokens following a state/province begin with a postal code from that region.
private nonisolated enum PostalRule: Sendable {
    /// Five-digit ZIP (optionally ZIP+4) whose first three digits fall in the state's ranges.
    case us([ClosedRange<Int>])
    /// Canadian postal code (or its first three characters) starting with one of the letters.
    case canada(Set<Character>)
    /// Four-digit postcode within the state's ranges.
    case australia([ClosedRange<Int>])
    /// Six-digit PIN code starting with one of the digits.
    case india(Set<Character>)

    func accepts(_ tokens: [String]) -> Bool {
        guard let first = tokens.first?.uppercased() else { return false }
        switch self {
        case .us(let ranges):
            // "78701", or the first half of "78701-1234".
            guard first.count == 5, first.allSatisfy(\.isASCIIDigit), let prefix = Int(first.prefix(3)) else { return false }
            return ranges.contains { $0.contains(prefix) }
        case .canada(let letters):
            guard let letter = first.first, letters.contains(letter) else { return false }
            return CountryNormalizer.isCanadianPostalCode(first)
        case .australia(let ranges):
            guard first.count == 4, first.allSatisfy(\.isASCIIDigit), let code = Int(first) else { return false }
            return ranges.contains { $0.contains(code) }
        case .india(let digits):
            guard first.count == 6, first.allSatisfy(\.isASCIIDigit), let digit = first.first else { return false }
            return digits.contains(digit)
        }
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { asciiValue.map { (0x30...0x39).contains($0) } ?? false }

    /// `isLetter || isNumber`, skipping the Unicode property lookup for ASCII.
    nonisolated var isWordCharacter: Bool {
        if let ascii = asciiValue {
            return (0x30...0x39).contains(ascii) || (0x41...0x5A).contains(ascii) || (0x61...0x7A).contains(ascii)
        }
        return isLetter || isNumber
    }
}

private extension UInt8 {
    nonisolated var isUpperASCII: Bool { (0x41...0x5A).contains(self) }
    nonisolated var isDigitASCII: Bool { (0x30...0x39).contains(self) }
}

private nonisolated struct Tables: Sendable {
    static let shared = Tables()

    /// Lowercased country names (English and several other languages) and aliases → ISO code.
    let countryNames: [String: String]
    /// Short aliases only accepted in capitals, so "us" in prose isn't read as a country.
    let uppercaseAliases: [String: String] = ["US": "US", "USA": "US", "UK": "GB", "UAE": "AE", "GB": "GB", "GBR": "GB"]
    let isoCodes: Set<String>
    let displayNames: [String: String]
    /// Lowercased state/province names and codes → candidate subdivisions.
    let subdivisions: [String: [Subdivision]]
    /// Lowercased state/province names that unambiguously identify a country → ISO code.
    let subdivisionNameCountries: [String: String]
    /// Names that contain a country name but aren't that country ("New Mexico", "Latin America").
    let blockedNames: Set<String>
    /// First words of multi-word keys, so scans only try longer phrases when one could match.
    let multiWordStarts: Set<String>

    static func key(_ words: [String]) -> String {
        var key = words.joined(separator: " ").lowercased()
        if key.hasPrefix("the ") { key.removeFirst(4) }
        return key
    }

    private init() {
        // Exclude pseudo-regions such as the EU and UN.
        let excluded: Set<String> = ["EU", "EZ", "UN", "QO", "ZZ", "XA", "XB"]
        let codes = Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) && !excluded.contains($0) }
        isoCodes = Set(codes)

        let english = Locale(identifier: "en_US")
        var display: [String: String] = [:]
        var names: [String: String] = [:]
        let languages = ["en", "es", "fr", "de", "pt", "it", "nl"].map { Locale(identifier: $0) }
        // System names that read oddly in a filter list.
        let displayOverrides = ["CN": "China"]
        for code in codes {
            guard let name = english.localizedString(forRegionCode: code) else { continue }
            display[code] = displayOverrides[code] ?? name
            for locale in languages {
                guard let localized = locale.localizedString(forRegionCode: code) else { continue }
                // Index the name as written plus common spellings: "Trinidad & Tobago" as
                // "Trinidad and Tobago", "St. Lucia" as "Saint Lucia", and "Myanmar (Burma)" as "Myanmar".
                var variants = [localized, localized.replacing("&", with: "and")]
                variants += variants.map { $0.replacing("St. ", with: "Saint ") }
                if let paren = localized.firstIndex(of: "(") { variants.append(String(localized[..<paren])) }
                for variant in variants {
                    names[Self.key(CountryNormalizer.words(CountryNormalizer.fold(variant))), default: code] = code
                }
            }
        }
        let aliases: [String: String] = [
            "united states of america": "US", "u s": "US", "u s a": "US",
            "great britain": "GB", "britain": "GB", "england": "GB", "scotland": "GB",
            "wales": "GB", "northern ireland": "GB",
            "united arab emirates": "AE", "emirates": "AE",
            "south korea": "KR", "korea": "KR", "republic of korea": "KR",
            "czech republic": "CZ", "czechia": "CZ", "holland": "NL", "netherlands": "NL",
            "russia": "RU", "russian federation": "RU", "ivory coast": "CI",
            "turkey": "TR", "turkiye": "TR", "hong kong": "HK", "macau": "MO", "macao": "MO",
            "taiwan": "TW", "vietnam": "VN", "viet nam": "VN",
            "dr congo": "CD", "democratic republic of the congo": "CD",
            "republic of the congo": "CG", "china": "CN", "mainland china": "CN", "prc": "CN",
            "palestine": "PS", "burma": "MM", "vatican": "VA",
        ]
        for (alias, code) in aliases { names[alias] = code }
        countryNames = names
        displayNames = display

        var subdivisions: [String: [Subdivision]] = [:]
        func add(_ country: String, code: String, name: String, rule: PostalRule) {
            subdivisions[code.lowercased(), default: []].append(Subdivision(countryCode: country, isCode: true, postalRule: rule))
            subdivisions[name.lowercased(), default: []].append(Subdivision(countryCode: country, isCode: false, postalRule: rule))
        }
        for state in Self.usStates { add("US", code: state.code, name: state.name, rule: .us(state.zipPrefixes)) }
        for province in Self.canadianProvinces { add("CA", code: province.code, name: province.name, rule: .canada(province.letters)) }
        for state in Self.australianStates { add("AU", code: state.code, name: state.name, rule: .australia(state.postcodes)) }
        for state in Self.indianStates {
            subdivisions[state.name.lowercased(), default: []].append(
                Subdivision(countryCode: "IN", isCode: false, postalRule: .india(state.digits)))
        }
        self.subdivisions = subdivisions

        // Full names that belong to exactly one country. Codes ("CA", "WA") and names shared
        // with countries or other regions still require a matching postal code.
        let ambiguousNames: Set<String> = ["georgia", "punjab", "victoria"]
        var nameCountries: [String: String] = [:]
        for (key, candidates) in subdivisions where !ambiguousNames.contains(key) {
            let named = candidates.filter { !$0.isCode }
            guard let country = named.first?.countryCode, named.count == candidates.count,
                  named.allSatisfy({ $0.countryCode == country }) else { continue }
            nameCountries[key] = country
        }
        subdivisionNameCountries = nameCountries

        // Multi-word state names that contain a country name, plus continents.
        var blocked: Set<String> = ["north america", "south america", "latin america", "central america"]
        for name in Self.usStates.map(\.name) + Self.canadianProvinces.map(\.name)
            + Self.australianStates.map(\.name) + Self.indianStates.map(\.name) {
            blocked.insert(name.lowercased())
        }
        blockedNames = blocked

        let allKeys = Array(names.keys) + Array(subdivisions.keys) + Array(blocked)
        multiWordStarts = Set(allKeys.compactMap { key in
            key.contains(" ") ? key.split(separator: " ").first.map(String.init) : nil
        })
    }

    // MARK: Subdivision data

    /// First three digits of ZIP codes assigned to each state.
    private static let usStates: [(code: String, name: String, zipPrefixes: [ClosedRange<Int>])] = [
        ("AL", "Alabama", [350...369]), ("AK", "Alaska", [995...999]), ("AZ", "Arizona", [850...865]),
        ("AR", "Arkansas", [716...729]), ("CA", "California", [900...961]), ("CO", "Colorado", [800...816]),
        ("CT", "Connecticut", [60...69]), ("DE", "Delaware", [197...199]),
        ("DC", "District of Columbia", [200...205, 569...569]), ("FL", "Florida", [320...349]),
        ("GA", "Georgia", [300...319, 398...399]), ("HI", "Hawaii", [967...968]), ("ID", "Idaho", [832...838]),
        ("IL", "Illinois", [600...629]), ("IN", "Indiana", [460...479]), ("IA", "Iowa", [500...528]),
        ("KS", "Kansas", [660...679]), ("KY", "Kentucky", [400...427]), ("LA", "Louisiana", [700...714]),
        ("ME", "Maine", [39...49]), ("MD", "Maryland", [206...219]), ("MA", "Massachusetts", [10...27, 55...55]),
        ("MI", "Michigan", [480...499]), ("MN", "Minnesota", [550...567]), ("MS", "Mississippi", [386...397]),
        ("MO", "Missouri", [630...658]), ("MT", "Montana", [590...599]), ("NE", "Nebraska", [680...693]),
        ("NV", "Nevada", [889...898]), ("NH", "New Hampshire", [30...38]), ("NJ", "New Jersey", [70...89]),
        ("NM", "New Mexico", [870...884]), ("NY", "New York", [5...5, 63...63, 100...149]),
        ("NC", "North Carolina", [270...289]), ("ND", "North Dakota", [580...588]), ("OH", "Ohio", [430...459]),
        ("OK", "Oklahoma", [730...749]), ("OR", "Oregon", [970...979]), ("PA", "Pennsylvania", [150...196]),
        ("RI", "Rhode Island", [28...29]), ("SC", "South Carolina", [290...299]), ("SD", "South Dakota", [570...577]),
        ("TN", "Tennessee", [370...385]), ("TX", "Texas", [750...799, 885...885]), ("UT", "Utah", [840...847]),
        ("VT", "Vermont", [50...59]), ("VA", "Virginia", [201...201, 220...246]), ("WA", "Washington", [980...994]),
        ("WV", "West Virginia", [247...268]), ("WI", "Wisconsin", [530...549]), ("WY", "Wyoming", [820...831]),
        ("PR", "Puerto Rico", [6...9]),
    ]

    /// First letter of postal codes for each province or territory.
    private static let canadianProvinces: [(code: String, name: String, letters: Set<Character>)] = [
        ("NL", "Newfoundland and Labrador", ["A"]), ("NS", "Nova Scotia", ["B"]),
        ("PE", "Prince Edward Island", ["C"]), ("NB", "New Brunswick", ["E"]),
        ("QC", "Quebec", ["G", "H", "J"]), ("ON", "Ontario", ["K", "L", "M", "N", "P"]),
        ("MB", "Manitoba", ["R"]), ("SK", "Saskatchewan", ["S"]), ("AB", "Alberta", ["T"]),
        ("BC", "British Columbia", ["V"]), ("NT", "Northwest Territories", ["X"]),
        ("NU", "Nunavut", ["X"]), ("YT", "Yukon", ["Y"]),
    ]

    private static let australianStates: [(code: String, name: String, postcodes: [ClosedRange<Int>])] = [
        ("NSW", "New South Wales", [1000...2599, 2620...2899, 2921...2999]),
        ("ACT", "Australian Capital Territory", [200...299, 2600...2619, 2900...2920]),
        ("VIC", "Victoria", [3000...3999, 8000...8999]), ("QLD", "Queensland", [4000...4999, 9000...9999]),
        ("SA", "South Australia", [5000...5999]), ("WA", "Western Australia", [6000...6999]),
        ("TAS", "Tasmania", [7000...7999]), ("NT", "Northern Territory", [800...999]),
    ]

    /// First digit of PIN codes for each state.
    private static let indianStates: [(name: String, digits: Set<Character>)] = [
        ("Delhi", ["1"]), ("Haryana", ["1"]), ("Punjab", ["1"]), ("Himachal Pradesh", ["1"]),
        ("Uttar Pradesh", ["2"]), ("Uttarakhand", ["2"]), ("Rajasthan", ["3"]), ("Gujarat", ["3"]),
        ("Maharashtra", ["4"]), ("Goa", ["4"]), ("Madhya Pradesh", ["4"]), ("Chhattisgarh", ["4"]),
        ("Karnataka", ["5"]), ("Telangana", ["5"]), ("Andhra Pradesh", ["5"]),
        ("Tamil Nadu", ["6"]), ("Kerala", ["6"]), ("West Bengal", ["7"]), ("Odisha", ["7"]),
        ("Assam", ["7"]), ("Bihar", ["8"]), ("Jharkhand", ["8"]),
    ]
}

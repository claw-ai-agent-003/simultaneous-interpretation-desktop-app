import Foundation

// ============================================================
// MARK: - Term Dictionary
// ============================================================

/// Manages the terminology dictionary used for code-switching protection.
///
/// The dictionary serves two purposes:
/// 1. **Term protection**: Mark terms that should be preserved (not translated)
/// 2. **Language hinting**: Provide language context for ambiguous tokens
///
/// Dictionary sources (in priority order):
/// 1. User custom terms from UserDefaults
/// 2. User custom terms from external JSON file
/// 3. Built-in default dictionary (bundled `term_dictionary.json`)
final class TermDictionary: Sendable {

    // MARK: - Types

    /// JSON representation for persistence.
    private struct DictionaryFile: Codable {
        let version: Int
        let description: String
        let terms: [TermEntryJSON]

        struct TermEntryJSON: Codable {
            let term: String
            let language: LanguageTag
            let keep: Bool
            let category: TermCategory?
        }
    }

    // MARK: - Properties

    /// All loaded terms (default + custom), keyed by lowercase term for fast lookup.
    private var termLookup: [String: TermEntry]

    /// Terms loaded from the default bundled JSON.
    private let defaultTerms: [TermEntry]

    /// User custom terms loaded from UserDefaults.
    private var customTerms: [TermEntry]

    /// The UserDefaults key for custom term persistence.
    private let userDefaultsKey: String

    /// Case-insensitive term → entry index for fast lookup.
    private var indexByLowercase: [String: TermEntry]

    // MARK: - Init

    /// Creates a term dictionary with default bundled entries.
    /// - Parameter userDefaultsKey: UserDefaults key for custom term storage.
    init(userDefaultsKey: String = "com.interpretation.customTermDictionary") {
        self.userDefaultsKey = userDefaultsKey

        // Load default terms from bundled JSON
        let defaults = Self.loadDefaultTerms()
        self.defaultTerms = defaults

        // Load custom terms from UserDefaults
        let custom = Self.loadCustomTerms(userDefaultsKey: userDefaultsKey)
        self.customTerms = custom

        // Merge: custom terms override defaults
        var merged = [String: TermEntry]()
        for entry in defaults {
            merged[entry.term.lowercased()] = entry
        }
        for entry in custom {
            merged[entry.term.lowercased()] = entry
        }

        self.termLookup = merged
        self.indexByLowercase = merged
    }

    // MARK: - Public API

    /// Looks up a term in the dictionary.
    /// Case-insensitive matching.
    func lookup(_ term: String) -> TermEntry? {
        return indexByLowercase[term.lowercased()]
    }

    /// Checks if a term should be preserved (not translated).
    func shouldPreserve(_ term: String) -> Bool {
        guard let entry = lookup(term) else { return false }
        return entry.keep
    }

    /// Checks if the text contains any protected terms.
    /// Returns all matching protected terms found in the text.
    func findProtectedTerms(in text: String) -> [String] {
        var found: [String] = []
        let lowerText = text.lowercased()

        for (lowerTerm, entry) in indexByLowercase where entry.keep {
            if lowerText.contains(lowerTerm) {
                found.append(entry.term)
            }
        }

        return found
    }

    /// Returns the number of terms in the dictionary (default + custom).
    var count: Int {
        return indexByLowercase.count
    }

    /// Returns all custom terms.
    func getCustomTerms() -> [TermEntry] {
        return customTerms
    }

    /// Adds a custom term. Persists to UserDefaults.
    /// - Parameters:
    ///   - term: The term text.
    ///   - language: Language of the term.
    ///   - keep: Whether to preserve the term.
    ///   - category: Optional category.
    func addCustomTerm(term: String, language: LanguageTag, keep: Bool = true, category: TermCategory? = nil) {
        let entry = TermEntry(term: term, language: language, keep: keep, category: category ?? .custom)

        // Update in-memory
        customTerms.append(entry)
        indexByLowercase[term.lowercased()] = entry
        termLookup[term.lowercased()] = entry

        // Persist to UserDefaults
        persistCustomTerms()
    }

    /// Removes a custom term by its text.
    /// - Parameter term: The term text to remove (case-insensitive).
    /// - Returns: The removed entry, or nil if not found.
    @discardableResult
    func removeCustomTerm(_ term: String) -> TermEntry? {
        let lowerKey = term.lowercased()

        guard customTerms.contains(where: { $0.term.lowercased() == lowerKey }) else {
            return nil
        }

        customTerms.removeAll(where: { $0.term.lowercased() == lowerKey })

        // Revert to default if one exists
        if let defaultEntry = defaultTerms.first(where: { $0.term.lowercased() == lowerKey }) {
            indexByLowercase[lowerKey] = defaultEntry
            termLookup[lowerKey] = defaultEntry
        } else {
            indexByLowercase.removeValue(forKey: lowerKey)
            termLookup.removeValue(forKey: lowerKey)
        }

        persistCustomTerms()
        return indexByLowercase[lowerKey]
    }

    /// Loads custom terms from an external JSON file.
    /// Custom terms from the file are merged with existing custom terms.
    /// - Parameter url: URL to the JSON file.
    /// - Returns: Number of terms successfully loaded.
    @discardableResult
    func loadCustomTermsFromFile(url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }

        do {
            let file = try JSONDecoder().decode(DictionaryFile.self, from: data)
            var loaded = 0

            for termJSON in file.terms {
                let entry = TermEntry(
                    term: termJSON.term,
                    language: termJSON.language,
                    keep: termJSON.keep,
                    category: termJSON.category ?? .custom
                )

                customTerms.append(entry)
                indexByLowercase[entry.term.lowercased()] = entry
                termLookup[entry.term.lowercased()] = entry
                loaded += 1
            }

            persistCustomTerms()
            return loaded
        } catch {
            print("Failed to load custom terms from file: \(error)")
            return 0
        }
    }

    /// Removes all custom terms and reloads defaults.
    func resetToDefaults() {
        customTerms.removeAll()
        indexByLowercase.removeAll()
        termLookup.removeAll()

        for entry in defaultTerms {
            indexByLowercase[entry.term.lowercased()] = entry
            termLookup[entry.term.lowercased()] = entry
        }

        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Private — Default Terms Loader

    /// Loads the built-in term dictionary from the bundled JSON file.
    private static func loadDefaultTerms() -> [TermEntry] {
        guard let url = Bundle.main.url(forResource: "term_dictionary", withExtension: "json") else {
            print("Warning: term_dictionary.json not found in bundle — using empty dictionary")
            return []
        }

        guard let data = try? Data(contentsOf: url) else {
            print("Warning: Failed to read term_dictionary.json")
            return []
        }

        do {
            let file = try JSONDecoder().decode(DictionaryFile.self, from: data)
            return file.terms.map { json in
                TermEntry(
                    term: json.term,
                    language: json.language,
                    keep: json.keep,
                    category: json.category
                )
            }
        } catch {
            print("Warning: Failed to parse term_dictionary.json: \(error)")
            return []
        }
    }

    // MARK: - Private — UserDefaults Persistence

    /// Loads custom terms from UserDefaults.
    private static func loadCustomTerms(userDefaultsKey: String) -> [TermEntry] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([TermEntry].self, from: data)
        } catch {
            print("Warning: Failed to load custom terms from UserDefaults: \(error)")
            return []
        }
    }

    /// Persists custom terms to UserDefaults.
    private func persistCustomTerms() {
        do {
            let data = try JSONEncoder().encode(customTerms)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("Warning: Failed to persist custom terms: \(error)")
        }
    }
}

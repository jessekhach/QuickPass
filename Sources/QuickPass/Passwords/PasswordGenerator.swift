import Foundation

/// The kinds of generated password, the same three 1Password offers.
enum PasswordStyle: Int, Codable {
    /// Random characters at a chosen length.
    case random = 1
    /// Everyday words joined by a separator, like "Cherub-motivate-zoom7-abacus".
    case memorable = 2
    /// Digits only.
    case pin = 3
}

/// The options for generated passwords. Remembered between uses.
struct PasswordRecipe: Codable, Equatable {
    var style: PasswordStyle = .memorable
    var length = 20
    var uppercase = true
    var numbers = true
    var symbols = true
    var wordCount = 4
    var separator = "-"
    var capitalize = true
    var addNumber = true
    var pinLength = 6
}

enum PasswordGenerator {
    static func make(_ recipe: PasswordRecipe) -> String {
        // SystemRandomNumberGenerator draws from the system's cryptographically secure source.
        var random = SystemRandomNumberGenerator()
        switch recipe.style {
        case .random:
            var kinds = [lowercase]
            if recipe.uppercase { kinds.append(uppercase) }
            if recipe.numbers { kinds.append(digits) }
            if recipe.symbols { kinds.append(symbolSet) }
            // One of each chosen kind first, so strict sign-up rules are always met, then shuffled in.
            let pool = kinds.joined()
            var characters = kinds.map { $0.randomElement(using: &random)! }
            while characters.count < max(recipe.length, kinds.count) { characters.append(pool.randomElement(using: &random)!) }
            return String(characters.shuffled(using: &random))

        case .memorable:
            var words = (0..<max(recipe.wordCount, 1)).map { _ in dictionary.randomElement(using: &random) ?? "word" }
            if recipe.capitalize { words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
            if recipe.addNumber {
                let index = Int.random(in: words.indices, using: &random)
                words[index] += String(Int.random(in: 0...9, using: &random))
            }
            return words.joined(separator: recipe.separator)

        case .pin:
            return String((0..<max(recipe.pinLength, 1)).map { _ in digits.randomElement(using: &random)! })
        }
    }

    private static let lowercase = "abcdefghijklmnopqrstuvwxyz"
    private static let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let digits = "0123456789"
    /// Symbols nearly every site accepts. Leaves out quotes, backslash and spaces, which some reject.
    private static let symbolSet = "!@#$%^&*-_=+?"

    /// EFF's Large Wordlist: 7,776 everyday words chosen for passphrases, about 12.9 bits of
    /// randomness each. Lines read "11111<tab>abacus". The few with a hyphen are left out so they
    /// can't be confused with the separator.
    private static let dictionary: [String] = {
        guard let url = Bundle.main.url(forResource: "eff_large_wordlist", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").last.map(String.init)
        }.filter { !$0.contains("-") }
    }()
}

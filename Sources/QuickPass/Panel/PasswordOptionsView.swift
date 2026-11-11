import SwiftUI

/// Compact options for generated passwords, shown wherever a password is made. Choices are
/// remembered. Changing one calls changed, so the caller can make a new password.
struct PasswordOptionsView: View {
    @ObservedObject var preferences: Preferences
    let changed: () -> Void

    private var recipe: Binding<PasswordRecipe> { $preferences.passwordRecipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Type", selection: recipe.style) {
                    Text("Random").tag(PasswordStyle.random)
                    Text("Memorable").tag(PasswordStyle.memorable)
                    Text("PIN").tag(PasswordStyle.pin)
                }
                .fixedSize()
                switch preferences.passwordRecipe.style {
                case .random: slider("Characters", value: recipe.length, in: 8...64)
                case .memorable: slider("Words", value: recipe.wordCount, in: 3...10)
                case .pin: slider("Digits", value: recipe.pinLength, in: 4...12)
                }
            }
            switch preferences.passwordRecipe.style {
            case .random:
                HStack(spacing: 16) {
                    Toggle("Uppercase", isOn: recipe.uppercase)
                    Toggle("Numbers", isOn: recipe.numbers)
                    Toggle("Symbols", isOn: recipe.symbols)
                }
            case .memorable:
                HStack(spacing: 16) {
                    Toggle("Capitalize", isOn: recipe.capitalize)
                    Toggle("Number", isOn: recipe.addNumber)
                    Picker("Separator", selection: recipe.separator) {
                        Text("Hyphen").tag("-")
                        Text("Period").tag(".")
                        Text("Underscore").tag("_")
                        Text("Space").tag(" ")
                    }
                    .fixedSize()
                }
            case .pin:
                EmptyView()
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.system(size: 12))
        .onChange(of: preferences.passwordRecipe) { _, _ in changed() }
    }

    private func slider(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)").monospacedDigit().frame(width: 22, alignment: .trailing)
        }
    }
}

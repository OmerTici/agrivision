import Foundation

struct CountryCode: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let flag: String
    let dialCode: String

    static let turkey = CountryCode(id: "TR", name: "Turkey", flag: "🇹🇷", dialCode: "+90")

    static let all: [CountryCode] = [
        .turkey,
        CountryCode(id: "US", name: "United States", flag: "🇺🇸", dialCode: "+1"),
        CountryCode(id: "GB", name: "United Kingdom", flag: "🇬🇧", dialCode: "+44"),
        CountryCode(id: "DE", name: "Germany", flag: "🇩🇪", dialCode: "+49"),
        CountryCode(id: "FR", name: "France", flag: "🇫🇷", dialCode: "+33"),
        CountryCode(id: "IT", name: "Italy", flag: "🇮🇹", dialCode: "+39"),
        CountryCode(id: "ES", name: "Spain", flag: "🇪🇸", dialCode: "+34"),
        CountryCode(id: "NL", name: "Netherlands", flag: "🇳🇱", dialCode: "+31"),
        CountryCode(id: "AE", name: "UAE", flag: "🇦🇪", dialCode: "+971"),
        CountryCode(id: "SA", name: "Saudi Arabia", flag: "🇸🇦", dialCode: "+966"),
    ]
}

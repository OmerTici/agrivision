import SwiftUI

struct AddAnimalScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared

    @State private var name = ""
    @State private var tag = ""
    @State private var breed = "Holstein"
    @State private var sex: AnimalSex = .female
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
    @State private var weightText = ""
    @State private var muzzleScanned = false
    @State private var showSavedToast = false

    private let breeds = ["Holstein", "Angus", "Simmental", "Jersey", "Hereford", "Charolais", "Limousin"]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !tag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    muzzleScanCard
                    detailsCard
                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, CarniLayout.tabBarClearance)
            }
            .scrollDismissesKeyboard(.interactively)

            if showSavedToast {
                savedToast
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lang.t("add.title"))
                .font(CarniFont.bold(24))
                .foregroundStyle(CarniColors.purpleDark)
            Text(lang.t("add.subtitle"))
                .font(CarniFont.regular(13))
                .foregroundStyle(CarniColors.tabInactive)
        }
    }

    private var muzzleScanCard: some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { muzzleScanned.toggle() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: muzzleScanned ? "checkmark.seal.fill" : "viewfinder")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(muzzleScanned ? CarniColors.successGreen : CarniColors.purple)

                Text(lang.t(muzzleScanned ? "add.scanDone" : "add.scanPrompt"))
                    .font(CarniFont.semibold(15))
                    .foregroundStyle(muzzleScanned ? CarniColors.successGreen : CarniColors.purpleDark)

                Text(lang.t(muzzleScanned ? "add.scanHintDone" : "add.scanHint"))
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill((muzzleScanned ? CarniColors.successGreen : CarniColors.purple).opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        (muzzleScanned ? CarniColors.successGreen : CarniColors.purple).opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: muzzleScanned ? [] : [6, 5])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var detailsCard: some View {
        VStack(spacing: 16) {
            FormField(label: lang.t("add.name"), placeholder: lang.t("add.namePh"), text: $name)
            FormField(label: lang.t("add.tag"), placeholder: lang.t("add.tagPh"), text: $tag)

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.breed"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                Menu {
                    ForEach(breeds, id: \.self) { option in
                        Button(option) { breed = option }
                    }
                } label: {
                    HStack {
                        Text(breed)
                            .font(CarniFont.regular(15))
                            .foregroundStyle(CarniColors.purpleDark)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CarniColors.tabInactive)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackground)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("detail.sex"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                HStack(spacing: 8) {
                    ForEach(AnimalSex.allCases) { option in
                        Button {
                            sex = option
                        } label: {
                            Text(lang.t(option.key))
                                .font(CarniFont.semibold(14))
                                .foregroundStyle(sex == option ? .white : CarniColors.purple)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(sex == option ? CarniColors.purple : CarniColors.purple.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.dob"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                HStack {
                    DatePicker("", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .tint(CarniColors.purple)
                        .environment(\.locale, lang.language.locale)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(fieldBackground)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(lang.t("add.weight"))
                    .font(CarniFont.semibold(13))
                    .foregroundStyle(CarniColors.purpleDark)
                HStack {
                    TextField(lang.t("add.weightPh"), text: $weightText)
                        .font(CarniFont.regular(15))
                        .foregroundStyle(CarniColors.purpleDark)
                        .keyboardType(.decimalPad)
                    Text("kg")
                        .font(CarniFont.semibold(14))
                        .foregroundStyle(CarniColors.tabInactive)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldBackground)
            }
        }
        .carniCard()
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(CarniColors.appBackground)
    }

    private var saveButton: some View {
        Button(action: save) {
            Text(lang.t("add.save"))
                .font(CarniFont.bold(16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canSave ? CarniColors.purple : CarniColors.purple.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    private var savedToast: some View {
        Label(lang.t("add.saved"), systemImage: "checkmark.circle.fill")
            .font(CarniFont.semibold(14))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(CarniColors.successGreen))
            .shadow(color: CarniColors.successGreen.opacity(0.35), radius: 10, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func save() {
        store.addAnimal(
            name: name.trimmingCharacters(in: .whitespaces),
            tag: tag.trimmingCharacters(in: .whitespaces),
            breed: breed,
            sex: sex,
            birthDate: birthDate,
            initialWeightKg: Double(weightText.replacingOccurrences(of: ",", with: ".")),
            muzzleRegistered: muzzleScanned
        )

        name = ""
        tag = ""
        weightText = ""
        muzzleScanned = false

        withAnimation(.spring(duration: 0.35)) { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.3)) { showSavedToast = false }
        }
    }
}

private struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(CarniFont.semibold(13))
                .foregroundStyle(CarniColors.purpleDark)
            TextField(placeholder, text: $text)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CarniColors.appBackground)
                )
        }
    }
}

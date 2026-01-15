import SwiftUI
import UIKit

struct ProfileCaptureView: View {
    @Binding var profile: ProfileData
    var isSaving: Bool
    var errorText: String?
    var onContinue: () -> Void

    private enum Field {
        case name
        case phone
        case email
    }

    @FocusState private var focusedField: Field?
    @State private var lastFocused: Field?
    @State private var didEditName = false
    @State private var didEditPhone = false
    @State private var didEditEmail = false
    @State private var animateIn = false

    private var nameValid: Bool { !profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var phoneValid: Bool { profile.phone.range(of: "\\d", options: .regularExpression) != nil }
    private var emailValid: Bool { profile.email.contains("@") }
    private var formValid: Bool { nameValid && phoneValid && emailValid }

    var body: some View {
        ScrollView {
            OnboardingContainer {
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        HStack {
                            OnboardingChip(text: "Step 1 of 4")
                            Spacer()
                            OnboardingChip(text: "Welcome to HushhTech")
                        }

                        ProgressDots(total: 4, current: 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 6)
                    .animation(.easeOut(duration: 0.35).delay(0.05), value: animateIn)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick profile")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(HVTheme.botText)
                        Text("So Kai can address you properly.")
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(HVTheme.botText.opacity(0.7))
                        Text("Only basics. Nothing sensitive.")
                            .font(.footnote)
                            .foregroundStyle(HVTheme.botText.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
                    .animation(.easeOut(duration: 0.4).delay(0.12), value: animateIn)

                    VStack(spacing: 16) {
                        ProfileField(
                            title: "Full name",
                            icon: "person.fill",
                            text: $profile.fullName,
                            showValid: didEditName && nameValid,
                            showInvalid: didEditName && !nameValid,
                            keyboard: .default,
                            autocapitalize: true,
                            isFocused: focusedField == .name
                        )
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .phone }

                        ProfileField(
                            title: "Phone",
                            icon: "phone.fill",
                            text: $profile.phone,
                            showValid: didEditPhone && phoneValid,
                            showInvalid: didEditPhone && !phoneValid,
                            keyboard: .phonePad,
                            autocapitalize: false,
                            isFocused: focusedField == .phone
                        )
                        .focused($focusedField, equals: .phone)

                        ProfileField(
                            title: "Email",
                            icon: "envelope.fill",
                            text: $profile.email,
                            showValid: didEditEmail && emailValid,
                            showInvalid: didEditEmail && !emailValid,
                            keyboard: .emailAddress,
                            autocapitalize: false,
                            isFocused: focusedField == .email
                        )
                        .focused($focusedField, equals: .email)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.surface.opacity(0.7),
                                        HVTheme.surfaceAlt.opacity(0.6)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
                    )
                    .opacity(animateIn ? 1 : 0)
                    .scaleEffect(animateIn ? 1.0 : 0.98)
                    .animation(.easeOut(duration: 0.45).delay(0.2), value: animateIn)

                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        onContinue()
                    } label: {
                        HStack {
                            Text(isSaving ? "Saving..." : "Continue")
                                .font(.headline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            HVTheme.accent.opacity(formValid ? 0.95 : 0.3),
                                            HVTheme.accent.opacity(formValid ? 0.75 : 0.2)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: formValid ? HVTheme.accent.opacity(0.35) : .clear, radius: 12, x: 0, y: 6)
                        )
                    }
                    .foregroundColor(formValid ? .black : HVTheme.botText.opacity(0.5))
                    .disabled(!formValid || isSaving)
                    .buttonStyle(PressableButtonStyle())
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
                    .animation(.easeOut(duration: 0.35).delay(0.28), value: animateIn)

                    Text("Kai is your private financial agent.")
                        .font(.footnote)
                        .foregroundStyle(HVTheme.botText.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(animateIn ? 1 : 0)
                        .animation(.easeOut(duration: 0.3).delay(0.32), value: animateIn)
                }
                .padding(.vertical, 24)
            }
        }
        .scrollIndicators(.hidden)
        .modifier(KeyboardDismissModifier())
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                if focusedField == .phone {
                    Button("Next") { focusedField = .email }
                } else if focusedField == .email {
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .onChange(of: focusedField) { newValue in
            if lastFocused == .name && newValue != .name { didEditName = true }
            if lastFocused == .phone && newValue != .phone { didEditPhone = true }
            if lastFocused == .email && newValue != .email { didEditEmail = true }
            lastFocused = newValue
        }
        .onAppear { animateIn = true }
    }
}

struct ProfileField: View {
    var title: String
    var icon: String
    @Binding var text: String
    var showValid: Bool
    var showInvalid: Bool
    var keyboard: UIKeyboardType
    var autocapitalize: Bool = true
    var isFocused: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(HVTheme.surface.opacity(0.7)))
                .overlay(Circle().stroke(Color.white.opacity(0.08)))

            TextField(title, text: $text, prompt: Text(title).foregroundColor(HVTheme.botText.opacity(0.4)))
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .words : .never)
                .autocorrectionDisabled(true)
                .foregroundStyle(HVTheme.botText)

            if showValid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HVTheme.accent)
                    .transition(.scale.combined(with: .opacity))
            } else if showInvalid {
                Circle()
                    .stroke(HVTheme.accent.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surfaceAlt.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isFocused ? HVTheme.accent.opacity(0.4) : Color.white.opacity(0.06))
        )
        .shadow(color: isFocused ? HVTheme.accent.opacity(0.18) : .clear, radius: 8, x: 0, y: 4)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showValid)
    }
}

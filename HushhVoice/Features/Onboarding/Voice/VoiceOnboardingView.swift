import SwiftUI

struct VoiceOnboardingView: View {
    @ObservedObject var vm: KaiVoiceViewModel
    @ObservedObject var micMonitor: MicLevelMonitor
    var preserveStateOnStart: Bool
    var onClose: () -> Void
    var onFinish: () -> Void
    @State private var showFinishPrompt = false

    var body: some View {
        VStack(spacing: 16) {
            OnboardingContainer {
                VStack(spacing: 16) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kai")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(HVTheme.botText.opacity(0.95))

                            Text(vm.subtitle)
                                .font(.footnote)
                                .foregroundStyle(HVTheme.botText.opacity(0.6))
                        }

                        Spacer()

                        ProgressChip(
                            completed: vm.completedQuestions,
                            total: vm.totalQuestions
                        )

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(HVTheme.surfaceAlt))
                                .overlay(Circle().stroke(HVTheme.stroke))
                        }
                        .foregroundStyle(HVTheme.botText)
                    }

                }
                .padding(.top, 12)
            }

            Spacer()

            KaiOrb(configuration: vm.orbConfiguration, size: 270)
                .padding(.bottom, 6)

            WaveformView(level: micMonitor.level, isMuted: vm.isMuted, accent: HVTheme.accent)
                .padding(.horizontal, 24)
                .opacity(vm.state == .connecting ? 0.55 : 0.7)

            if !showFinishPrompt {
                KaiNotesCard(notes: vm.notes)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showFinishPrompt {
                FinishKaiCard(onFinish: onFinish)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            QuietMicButtonSmall(isMuted: $vm.isMuted) {
                vm.setMuted(vm.isMuted)
            }
            .disabled(vm.state == .connecting)

            if let err = vm.errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Text(vm.footerText)
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.55))
                .padding(.bottom, 14)
        }
        .onAppear {
            micMonitor.start()
            micMonitor.setMuted(vm.isMuted)
            if !vm.isRunningSession, !vm.userIdValue.isEmpty {
                vm.start(userId: vm.userIdValue, preserveState: preserveStateOnStart)
            } else {
                vm.repeatLastPromptIfNeeded()
            }
        }
        .onDisappear {
            micMonitor.stop()
        }
        .onChange(of: vm.isMuted) { muted in
            micMonitor.setMuted(muted)
        }
        .onChange(of: vm.isComplete) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                showFinishPrompt = vm.isComplete || vm.shouldExitOnboarding
            }
        }
        .onChange(of: vm.shouldExitOnboarding) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                showFinishPrompt = vm.isComplete || vm.shouldExitOnboarding
            }
        }
    }
}

struct FinishKaiCard: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("That’s all 8 questions.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HVTheme.botText)

            Text("Ready to wrap up and review your summary?")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.65))
                .multilineTextAlignment(.center)

            Button(action: onFinish) {
                HStack(spacing: 10) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("End Chat with Kai")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(HVTheme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
                )
            }
            .foregroundColor(.black)
            .buttonStyle(PressableButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surface.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
        )
    }
}

struct ProgressChip: View {
    var completed: Int
    var total: Int

    var body: some View {
        let shownTotal = max(total, 1)
        let shownCompleted = min(completed + 1, shownTotal)
        Text("Step \(shownCompleted) of \(shownTotal)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(HVTheme.surfaceAlt))
            .overlay(Capsule().stroke(HVTheme.stroke))
            .foregroundStyle(HVTheme.botText.opacity(0.8))
    }
}

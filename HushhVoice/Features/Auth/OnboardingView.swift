import SwiftUI

// Static "how to use" guide shown from settings.
struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to HushhVoice").font(.system(size: 28, weight: .bold))
                        Text("Your private, consent-first AI copilot.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Text("What you can do").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Ask questions in natural language.", systemImage: "text.bubble")
                            Label("Summarize or draft replies to your email.", systemImage: "envelope.badge")
                            Label("Check your schedule or plan events.", systemImage: "calendar")
                            Label("Use it like a smart, trustworthy assistant for your day.", systemImage: "brain.head.profile")
                        }
                        .font(.subheadline)
                    }

                    Group {
                        Text("Using HushhVoice with Siri").font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("How it currently works:").font(.subheadline)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("1. Say: “Hey Siri, ask HushhVoice…” and pause.")
                                Text("2. Siri will respond: “What is the Question”")
                                Text("3. Then say your request, like:")
                                Text("   • “Check my email.”")
                                Text("   • “What meetings do I have today?”")
                                Text("   • “Draft a reply to my last email.”")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }

                    Group {
                        Text("Email & Calendar").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Connect Google to let HushhVoice read and summarize your Gmail inbox.", systemImage: "envelope.open")
                            Label("Ask natural questions like “Anything urgent from today?”", systemImage: "exclamationmark.circle")
                            Label("Let it check your Google Calendar or help schedule meetings.", systemImage: "calendar.badge.clock")
                        }
                        .font(.subheadline)
                    }

                    Group {
                        Text("Privacy & Consent").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HushhVoice uses your Google token only to talk to Gmail and Calendar on your behalf.")
                            Text("You stay in control: you can disconnect at any time from Settings.")
                            Text("Your data. Your business.")
                        }
                        .font(.subheadline)
                    }

                    Spacer(minLength: 8)
                }
                .padding()
            }
            .navigationTitle("How to use HushhVoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

import SwiftUI

// Sidebar listing chats with rename/delete actions.
struct ChatSidebar: View {
    @ObservedObject var store: ChatStore
    @Binding var showingSettings: Bool
    @Binding var isCollapsed: Bool

    @State private var renamingChatID: UUID?
    @State private var renameText: String = ""

    @State private var showRenameAlert = false
    @State private var pendingRenameChatID: UUID?
    @State private var pendingRenameTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline).foregroundColor(HVTheme.botText)
                Spacer()
                Button { store.newChat(select: true) } label: {
                    Label("New", systemImage: "plus.circle.fill").labelStyle(.iconOnly)
                }
                .tint(HVTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(HVTheme.bg.opacity(0.98))

            Divider().background(HVTheme.stroke)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.chats) { chat in
                        let isActive = (chat.id == store.activeChatID)

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                store.selectChat(chat.id)
                                isCollapsed = false
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: isActive ? "message.fill" : "message")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(isActive ? HVTheme.accent : HVTheme.botText.opacity(0.7))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    if renamingChatID == chat.id {
                                        TextField("Title", text: $renameText, onCommit: { commitInlineRename(chat.id) })
                                            .textFieldStyle(.roundedBorder)
                                            .foregroundStyle(HVTheme.botText)
                                    } else {
                                        Text(chat.title.isEmpty ? "Untitled" : chat.title)
                                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                                            .foregroundStyle(HVTheme.botText)
                                            .lineLimit(2)
                                    }
                                    Text(chat.updatedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(HVTheme.botText.opacity(0.5))
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? (HVTheme.isDark ? Color.white.opacity(0.08) : Color.white) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? HVTheme.accent.opacity(0.5) : HVTheme.stroke,
                                            lineWidth: isActive ? 1.5 : 1)
                            )
                        }
                        .contextMenu {
                            Button("Rename") {
                                if #available(iOS 17.0, *) {
                                    pendingRenameChatID = chat.id
                                    pendingRenameTitle = chat.title
                                    showRenameAlert = true
                                } else {
                                    renamingChatID = chat.id
                                    renameText = chat.title
                                }
                            }
                            Button(role: .destructive) {
                                store.deleteChat(chat.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.deleteChat(chat.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                renamingChatID = chat.id
                                renameText = chat.title
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(HVTheme.accent)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 6)

            Button { showingSettings = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold))
                    Text("Settings").font(.subheadline)
                }
                .foregroundStyle(HVTheme.botText)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(HVTheme.surfaceAlt)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                )
                .padding([.horizontal, .bottom], 10)
            }
            .tint(HVTheme.accent)
        }
        .frame(width: HVTheme.sidebarWidth)
        .background(HVTheme.bg)
        .shadow(color: HVTheme.isDark ? .black.opacity(0.5) : .black.opacity(0.12),
                radius: HVTheme.isDark ? 14 : 6, x: 0, y: 0)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .ifAvailableiOS17RenameAlert(
            show: $showRenameAlert,
            title: $pendingRenameTitle,
            onSave: {
                if let id = pendingRenameChatID {
                    store.renameChat(id, to: pendingRenameTitle)
                    pendingRenameChatID = nil
                    pendingRenameTitle = ""
                }
            },
            onCancel: {
                pendingRenameChatID = nil
                pendingRenameTitle = ""
            }
        )
    }

    private func commitInlineRename(_ chatID: UUID) {
        // Save inline rename edits.
        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameChat(chatID, to: newTitle)
        renamingChatID = nil
        renameText = ""
    }
}

fileprivate extension View {
    // Helper to show the iOS 17 rename alert when available.
    func ifAvailableiOS17RenameAlert(
        show: Binding<Bool>,
        title: Binding<String>,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(RenameAlertModifier(show: show, title: title, onSave: onSave, onCancel: onCancel))
    }
}

fileprivate struct RenameAlertModifier: ViewModifier {
    @Binding var show: Bool
    @Binding var title: String
    var onSave: () -> Void
    var onCancel: () -> Void

    func body(content: Content) -> some View {
        // Use the native iOS 17 alert with a text field.
        if #available(iOS 17.0, *) {
            content.alert("Rename Chat", isPresented: $show) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave() }
            } message: { Text("Enter a new title.") }
        } else {
            content
        }
    }
}

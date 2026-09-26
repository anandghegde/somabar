import SomabarCore
import SwiftUI

/// The profile list, and per profile: its name, where new items go, and what the notch shows.
/// Each profile's layout is edited by ⌘-dragging in the bar, not here.
struct ProfilesSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(model.document.profiles, id: \.name, selection: $selection) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if profile.name == model.document.activeProfile {
                            Text("Active").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { selection = model.addProfile() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add a profile, copied from the active one")
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil || model.document.profiles.count < 2)
                        .help("Remove the selected profile")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 180)
            Divider()
            if let name = selection, let profile = model.document.profile(named: name) {
                ProfileDetailView(model: model, profile: profile) { selection = $0 }
                    .id(profile.id)
            } else {
                Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? model.document.activeProfile }
    }

    private func removeSelected() {
        guard let name = selection else { return }
        try? model.removeProfile(named: name)
        selection = model.document.activeProfile
    }
}

private struct ProfileDetailView: View {
    var model: SettingsModel
    var profile: Profile
    var onRenamed: (String) -> Void
    @State private var name = ""
    @State private var renameError: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Name", text: $name)
                    .onSubmit(rename)
                if let renameError {
                    Text(renameError).font(.caption).foregroundStyle(.orange)
                }
                Picker("New items go to", selection: binding(\.newItemsGoTo)) {
                    ForEach(SomabarCore.Section.allCases, id: \.self) { section in
                        Text(section.displayName).tag(section)
                    }
                }
            } footer: {
                Text("Press ↩ to rename. Triggers that switch to this profile follow the new name.")
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section("Notch") {
                Toggle("Show artwork and file names", isOn: binding(\.notch.showsArtworkAndFileNames))
                ForEach(ActivityKind.allCases, id: \.self) { kind in
                    Toggle(kind.settingsName, isOn: activityBinding(kind))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = profile.name }
    }

    private func rename() {
        do {
            try model.renameProfile(profile.name, to: name)
            renameError = nil
            onRenamed(name.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            renameError = switch error {
            case .emptyName: "A profile needs a name."
            case .nameTaken: "Another profile already has that name."
            case .lastProfile, .noSuchProfile: "Could not rename the profile."
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding(
            get: { (model.document.profiles.first { $0.id == profile.id } ?? profile)[keyPath: path] },
            set: { value in
                guard var current = model.document.profiles.first(where: { $0.id == profile.id }) else { return }
                current[keyPath: path] = value
                model.updateProfile(current)
            }
        )
    }

    private func activityBinding(_ kind: ActivityKind) -> Binding<Bool> {
        let activities = binding(\.notch.enabledActivities)
        return Binding(
            get: { activities.wrappedValue.contains(kind) },
            set: { isOn in
                var set = activities.wrappedValue
                if isOn { set.insert(kind) } else { set.remove(kind) }
                activities.wrappedValue = set
            }
        )
    }
}

extension ActivityKind {
    var settingsName: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .timer: "Timer"
        case .call: "Calls"
        case .charging: "Charging"
        case .dropToShare: "Drop to share"
        case .transfers: "Transfers"
        case .volumeHUD: "Volume"
        case .focus: "Focus"
        case .hiddenItemsTray: "Hidden items tray"
        case .screenShareGuard: "Screen share guard"
        case .agentActivity: "Agent activity"
        }
    }
}

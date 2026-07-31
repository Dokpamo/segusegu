import Combine
import Foundation

/// A process-local snapshot of the provider configuration shared by native UI.
///
/// Rust remains the source of truth. This store only lets Settings and Chat
/// observe a confirmed configuration change without persisting credentials or
/// duplicating provider logic in Swift.
@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var profiles: [ProviderProfile]
    @Published public private(set) var selectedProfileID: String?
    @Published public private(set) var quarantinedProfileIDs: Set<String>
    @Published public private(set) var mutatingProfileIDs: Set<String>
    @Published public private(set) var revision: UInt64 = 0

    public init(
        profiles: [ProviderProfile] = [],
        selectedProfileID: String? = nil,
        quarantinedProfileIDs: Set<String> = [],
        mutatingProfileIDs: Set<String> = []
    ) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.quarantinedProfileIDs = quarantinedProfileIDs
        self.mutatingProfileIDs = mutatingProfileIDs
    }

    public func replace(
        profiles: [ProviderProfile],
        selectedProfileID: String?
    ) {
        let sortedProfiles = profiles.sorted(by: Self.profileSort)
        let validSelection = sortedProfiles.contains {
            $0.id == selectedProfileID
        } ? selectedProfileID : nil
        guard self.profiles != sortedProfiles
            || self.selectedProfileID != validSelection
        else {
            return
        }

        self.profiles = sortedProfiles
        self.selectedProfileID = validSelection
        revision &+= 1
    }

    public func quarantine(profileID: String) {
        guard quarantinedProfileIDs.insert(profileID).inserted else {
            return
        }
        revision &+= 1
    }

    public func clearQuarantine(profileID: String) {
        guard quarantinedProfileIDs.remove(profileID) != nil else {
            return
        }
        revision &+= 1
    }

    public func isQuarantined(profileID: String) -> Bool {
        quarantinedProfileIDs.contains(profileID)
    }

    public func beginMutation(profileID: String) {
        guard mutatingProfileIDs.insert(profileID).inserted else {
            return
        }
        revision &+= 1
    }

    public func endMutation(profileID: String) {
        guard mutatingProfileIDs.remove(profileID) != nil else {
            return
        }
        revision &+= 1
    }

    public func isBlocked(profileID: String) -> Bool {
        mutatingProfileIDs.contains(profileID)
            || quarantinedProfileIDs.contains(profileID)
    }

    private static func profileSort(
        _ lhs: ProviderProfile,
        _ rhs: ProviderProfile
    ) -> Bool {
        if lhs.displayName == rhs.displayName {
            if lhs.model == rhs.model {
                return lhs.id.localizedStandardCompare(rhs.id)
                    == .orderedAscending
            }
            return lhs.model.localizedStandardCompare(rhs.model)
                == .orderedAscending
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName)
            == .orderedAscending
    }
}

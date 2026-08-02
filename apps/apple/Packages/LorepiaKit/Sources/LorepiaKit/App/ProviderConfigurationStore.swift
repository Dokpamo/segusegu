import Combine
import Foundation

/// A process-local snapshot of the provider configuration shared by native UI.
///
/// Rust remains the source of truth. This store only lets Settings and Chat
/// observe a confirmed configuration change without persisting credentials or
/// duplicating provider logic in Swift.
@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var connections: [
        ProviderConnectionRecord
    ]
    @Published public private(set) var selectedConnectionID: String?
    @Published public private(set) var selectedGenerationTarget:
        ProviderGenerationTarget?
    @Published public private(set) var profiles: [ProviderProfile]
    @Published public private(set) var selectedProfileID: String?
    @Published public private(set) var quarantinedProfileIDs: Set<String>
    @Published public private(set) var mutatingProfileIDs: Set<String>
    @Published public private(set) var revision: UInt64 = 0

    public init(
        connections: [ProviderConnectionRecord] = [],
        selectedConnectionID: String? = nil,
        selectedGenerationTarget: ProviderGenerationTarget? = nil,
        profiles: [ProviderProfile] = [],
        selectedProfileID: String? = nil,
        quarantinedProfileIDs: Set<String> = [],
        mutatingProfileIDs: Set<String> = []
    ) {
        self.connections = connections
        self.selectedConnectionID = selectedConnectionID
        self.selectedGenerationTarget = selectedGenerationTarget
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.quarantinedProfileIDs = quarantinedProfileIDs
        self.mutatingProfileIDs = mutatingProfileIDs
    }

    public func replace(
        connections: [ProviderConnectionRecord],
        selectedConnectionID: String?,
        selectedGenerationTarget: ProviderGenerationTarget?
    ) {
        let sortedConnections = connections.sorted {
            if $0.displayName == $1.displayName {
                return $0.id.localizedStandardCompare($1.id)
                    == .orderedAscending
            }
            return $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
        let validConnectionID = sortedConnections.contains {
            $0.id == selectedConnectionID
        } ? selectedConnectionID : nil
        let validTarget = validConnectionID == nil
            ? nil
            : selectedGenerationTarget
        guard self.connections != sortedConnections
            || self.selectedConnectionID != validConnectionID
            || self.selectedGenerationTarget != validTarget
        else {
            return
        }

        self.connections = sortedConnections
        self.selectedConnectionID = validConnectionID
        self.selectedGenerationTarget = validTarget
        revision &+= 1
    }

    public func replace(
        connections: [ProviderConnectionRecord],
        selectedConnectionID: String?,
        selectedGenerationTarget: ProviderGenerationTarget?,
        profiles: [ProviderProfile],
        selectedProfileID: String?
    ) {
        let sortedConnections = connections.sorted {
            if $0.displayName == $1.displayName {
                return $0.id.localizedStandardCompare($1.id)
                    == .orderedAscending
            }
            return $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
        let validConnectionID = sortedConnections.contains {
            $0.id == selectedConnectionID
        } ? selectedConnectionID : nil
        let validTarget = validConnectionID == nil
            ? nil
            : selectedGenerationTarget
        let sortedProfiles = profiles.sorted(by: Self.profileSort)
        let validProfileID = sortedProfiles.contains {
            $0.id == selectedProfileID
        } ? selectedProfileID : nil

        guard self.connections != sortedConnections
            || self.selectedConnectionID != validConnectionID
            || self.selectedGenerationTarget != validTarget
            || self.profiles != sortedProfiles
            || self.selectedProfileID != validProfileID
        else {
            return
        }

        self.connections = sortedConnections
        self.selectedConnectionID = validConnectionID
        self.selectedGenerationTarget = validTarget
        self.profiles = sortedProfiles
        self.selectedProfileID = validProfileID
        revision &+= 1
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

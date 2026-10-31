import Foundation

/// The settings-like singletons (`core.*`), each one record:
/// - `core.appSettings` (`appSettings`): one field per setting, so the Mac changing units and the
///   phone changing the pool length both stand (today's key-value blob had no time at all). Seeds
///   only what differs from the compiled default (§3 seeding rule 5).
/// - `core.modules` (`modules`): the choice as one value `v`; seeds only when it isn't "everything".
/// - `core.smartSettings` (`smart-settings`): the Smart Schedule snapshot every device already
///   exchanges, as one value, at its own `updatedAt`; the later one stands, as today.
/// - `core.wakePlan` (`wakePlan`, the phone's only): the plan the phone works out, as one value.
/// - `core.hubStatus` (`hubStatus`, the phone's only): what the phone reports, as one value.
/// - `core.hubRequest` (`requests`): what an iPad or the Mac asked the phone to do, a field per
///   kind of request; the phone does each once per new moment, as today.
enum SettingsAdapters {
    @MainActor
    static func adapter(_ stores: SyncStores) -> BoundAdapter {
        let settings = stores.settings, modules = stores.modules, smart = stores.smart, hub = stores.hubStatus
        return BoundAdapter("settings", [
            .single(AppSettings.syncType, id: AppSettings.syncID, shape: .fields,
                    value: { [weak settings] in settings?.syncSnapshot },
                    apply: { [weak settings] value, fields in
                        settings?.applySynced(value, cleared: Set(fields.filter { $0.value.isNull }.keys))
                        return .taken
                    },
                    defaultValue: { AppSettings.syncDefault }),
            .single(ModuleStore.syncType, id: ModuleStore.syncID, shape: .wrapped,
                    value: { [weak modules] in modules?.choice },
                    apply: { [weak modules] (value: ModuleChoice, _) in
                        modules?.applySynced(value)
                        return .taken
                    },
                    defaultValue: { ModuleChoice.everything }),
            .single(SmartScheduleStore.syncSettingsType, id: SmartScheduleStore.syncSettingsID, shape: .wrapped,
                    value: { [weak smart] in smart?.syncSettingsSnapshot },
                    apply: { [weak smart] (value: SmartScheduleStore.CloudSettingsSnapshot, _) in
                        guard let smart else { return .notYet }
                        if smart.adoptSyncedSettings(value) { return .taken }
                        return smart.syncSettingsSnapshot == value ? .taken : .keptOwn
                    },
                    seedClock: { [weak smart] in smart?.syncSettingsUpdatedAt }),
            .single(SmartScheduleStore.syncWakePlanType, id: SmartScheduleStore.syncWakePlanID, shape: .wrapped,
                    value: { [weak smart] in smart?.syncWakePlan },
                    apply: { [weak smart] (value: SmartScheduleStore.CloudWakePlanSnapshot, _) in
                        smart?.adoptSyncedWakePlan(value)
                        return .taken
                    },
                    seedClock: { [weak smart] in smart?.syncWakePlan?.generatedAt }),
            .single(HubStatusStore.syncStatusType, id: HubStatusStore.syncStatusID, shape: .wrapped,
                    value: { [weak hub] in
                        guard let status = hub?.status, status.updatedAt != .distantPast else { return nil }
                        return status
                    },
                    apply: { [weak hub] (value: HubStatus, _) in
                        hub?.adoptSynced(value)
                        return .taken
                    },
                    seedClock: { [weak hub] in hub?.status.updatedAt }),
            .single(HubStatusStore.syncRequestType, id: HubStatusStore.syncRequestID, shape: .fields,
                    value: { [weak hub] in
                        guard let requests = hub?.syncRequests, requests != HubRequests() else { return nil }
                        return requests
                    },
                    apply: { [weak hub] (value: HubRequests, _) in
                        hub?.adoptSynced(value)
                        return .taken
                    },
                    seedClock: { [weak hub] in
                        let requests = hub?.syncRequests
                        return [requests?.watchResync, requests?.backUpNow].compactMap { $0 }.max()
                    }),
        ])
    }
}

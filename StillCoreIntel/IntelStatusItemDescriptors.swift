import Foundation

extension StatusItemController {
    func makeStatusItemDisplayDescriptors(metrics: Metrics) -> [StatusItemDisplayDescriptor] {
        var descriptors = [StatusItemDisplayDescriptor.icon]

        if BatteryTrackerService.isBatteryAvailable {
            descriptors += [
                StatusItemDisplayDescriptor(
                    displayName: "Battery percent",
                    persistenceValue: "batteryPercent",
                    source: .batteryStatus(formatStatusItemBatteryPercent)
                ),
                StatusItemDisplayDescriptor(
                    displayName: "Battery icon",
                    persistenceValue: "batteryIcon",
                    source: .batteryIcon
                ),
            ]
        }

        if metrics.power.package != nil {
            descriptors.append(
                StatusItemDisplayDescriptor(
                    displayName: "Package power",
                    persistenceValue: "packagePower",
                    source: .metrics(
                        { $0.power.package },
                        formatStatusItemPower
                    )
                )
            )
        }

        descriptors.append(
            StatusItemDisplayDescriptor(
                displayName: "CPU load",
                persistenceValue: "totalCpuLoad",
                source: .metrics(
                    { metrics in
                        let count = metrics.cpu_usage.reduce(0) { $0 + $1.units }
                        if count == 0 { return nil }
                        let load = metrics.cpu_usage.reduce(0.0) {
                            $0 + $1.usage * Double($1.units)
                        }
                        return load / Double(count)
                    },
                    formatStatusItemUsage
                )
            )
        )

        descriptors += metrics.cpu_usage.enumerated().flatMap { index, cluster in
            [
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) load",
                    persistenceValue: "cpuClusterLoad:\(index)",
                    source: .metrics(
                        { sample in
                            if sample.cpu_usage.indices.contains(index) {
                                return sample.cpu_usage[index].usage
                            }
                            return nil
                        },
                        formatStatusItemUsage
                    )
                ),
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) frequency",
                    persistenceValue: "cpuClusterFrequency:\(index)",
                    source: .metrics(
                        { sample in
                            if sample.cpu_usage.indices.contains(index) {
                                return Double(sample.cpu_usage[index].frequencyMHz) / 1000
                            }
                            return nil
                        },
                        formatStatusItemFrequency
                    )
                ),
            ]
        }

        return descriptors
    }
}

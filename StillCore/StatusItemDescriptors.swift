import MacmonSwift

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

        descriptors += [
            StatusItemDisplayDescriptor(
                displayName: "System power",
                persistenceValue: "systemPower",
                source: .metrics(
                    { metrics in Double(metrics.power.board) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Chip power",
                persistenceValue: "chipPower",
                source: .metrics(
                    { metrics in Double(metrics.power.package) },
                    formatStatusItemPower
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Temperature",
                persistenceValue: "maxTemperature",
                source: .metrics(
                    { metrics in
                        Double(max(metrics.temperature.cpuAverage, metrics.temperature.gpuAverage))
                    },
                    formatStatusItemTemperature
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "CPU load",
                persistenceValue: "totalCpuLoad",
                source: .metrics(
                    { metrics in
                        let totalUnits = metrics.cpu_usage.reduce(0) {
                            $0 + Int($1.units)
                        }
                        let weightedUsage = metrics.cpu_usage.reduce(0 as Float) {
                            $0 + ($1.usage * Float($1.units))
                        }
                        return totalUnits > 0 ? Double(weightedUsage / Float(totalUnits)) : 0
                    },
                    formatStatusItemUsage
                )
            ),
        ]

        descriptors += metrics.cpu_usage.enumerated().flatMap { index, cluster in
            [
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) load",
                    persistenceValue: "cpuClusterLoad:\(index)",
                    source: .metrics(
                        { metrics in
                            if !metrics.cpu_usage.indices.contains(index) { return nil }
                            return Double(metrics.cpu_usage[index].usage)
                        },
                        formatStatusItemUsage
                    )
                ),
                StatusItemDisplayDescriptor(
                    displayName: "\(cluster.name) frequency",
                    persistenceValue: "cpuClusterFrequency:\(index)",
                    source: .metrics(
                        { metrics in
                            if !metrics.cpu_usage.indices.contains(index) { return nil }
                            return Double(metrics.cpu_usage[index].frequencyMHz) / 1000.0
                        },
                        formatStatusItemFrequency
                    )
                ),
            ]
        }

        descriptors += [
            StatusItemDisplayDescriptor(
                displayName: "RAM used",
                persistenceValue: "ramUsed",
                source: .metrics(
                    { metrics in Double(metrics.memory.ramUsage) / 1_073_741_824.0 },
                    formatStatusItemMemoryGb
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "RAM load",
                persistenceValue: "ramLoad",
                source: .metrics(
                    { metrics in
                        if metrics.memory.ramTotal <= 0 { return 0 }
                        return Double(metrics.memory.ramUsage) / Double(metrics.memory.ramTotal)
                    },
                    formatStatusItemUsage
                )
            ),
            StatusItemDisplayDescriptor(
                displayName: "Swap used",
                persistenceValue: "swapUsed",
                source: .metrics(
                    { metrics in Double(metrics.memory.swapUsage) / 1_073_741_824.0 },
                    formatStatusItemMemoryGb
                )
            ),
        ]

        return descriptors
    }
}

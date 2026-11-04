import Foundation

@main
struct ProcessQoSChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() {
        var usage = rusage_info_v6()
        usage.ri_cpu_time_qos_background = 100
        usage.ri_cpu_time_qos_utility = 50
        let first = ProcessSampler.QoSActivity(usage: usage, previous: nil)
        check(!first.isBackground, "First sample must not classify lifetime activity as background")
        let idle = ProcessSampler.QoSActivity(usage: usage, previous: first)
        check(!idle.isBackground, "An idle foreground process must retain its classification")

        for field in [\rusage_info_v6.ri_cpu_time_qos_background, \.ri_cpu_time_qos_maintenance] {
            var active = usage
            active[keyPath: field] += 1
            let background = ProcessSampler.QoSActivity(usage: active, previous: first)
            check(background.isBackground, "Background or Maintenance activity alone must dim the name")
            let idleBackground = ProcessSampler.QoSActivity(usage: active, previous: background)
            check(idleBackground.isBackground, "An idle background process must retain its classification")

            for other in [\rusage_info_v6.ri_cpu_time_qos_default, \.ri_cpu_time_qos_utility,
                          \.ri_cpu_time_qos_legacy, \.ri_cpu_time_qos_user_initiated,
                          \.ri_cpu_time_qos_user_interactive] {
                var mixed = active
                mixed.ri_cpu_time_qos_background += 1_000_000
                mixed[keyPath: other] += 1
                let foreground = ProcessSampler.QoSActivity(usage: mixed, previous: background)
                check(!foreground.isBackground, "Even one tick of non-background activity must restore the name")
                let idleForeground = ProcessSampler.QoSActivity(usage: mixed, previous: foreground)
                check(!idleForeground.isBackground, "Idle after non-background activity must retain the normal name")
                mixed.ri_cpu_time_qos_background += 1
                check(ProcessSampler.QoSActivity(usage: mixed, previous: foreground).isBackground,
                      "Historical non-background activity must not prevent a later background classification")
            }
            check(!ProcessSampler.QoSActivity(usage: active, previous: nil).isBackground,
                  "A new process identity must start unclassified")
            check(!ProcessSampler.QoSActivity(usage: rusage_info_v6(), previous: background).isBackground,
                  "Reset counters must clear a stale background classification")
        }
        print("PASS: first sample, background classes, all non-background classes, mixed activity, idle and reset")
    }
}

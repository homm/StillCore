// battery_mAh.c
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <pwd.h>
#include <stdio.h>
#include <stdbool.h>


static io_registry_entry_t _open_battery(void) {
    io_registry_entry_t entry = IO_OBJECT_NULL;
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iter
        ) == KERN_SUCCESS
    ) {
        entry = IOIteratorNext(iter);
        IOObjectRelease(iter);
    }
    return entry;
}

static bool _get_int_prop(io_registry_entry_t entry, CFStringRef key, int *out) {
    CFTypeRef val = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!val) return false;
    bool ok = CFGetTypeID(val) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)val, kCFNumberIntType, out);
    CFRelease(val);
    return ok;
}

static bool _get_bool_prop(io_registry_entry_t entry, CFStringRef key, bool *out) {
    CFTypeRef val = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!val) return false;
    bool ok = CFGetTypeID(val) == CFBooleanGetTypeID();
    *out = CFBooleanGetValue((CFBooleanRef)val);
    CFRelease(val);
    return ok;
}

bool get_battery_stats(int *current, int *max, int *design, bool *on_ac) {
    bool ok = false, ac;
    int cur=0, mx=0, dsg=0;
    
    io_registry_entry_t bat = _open_battery();
    if (bat == IO_OBJECT_NULL) {
        return false;
    }
    bool ok1 = _get_int_prop(bat, CFSTR("AppleRawCurrentCapacity"), &cur) ||
               _get_int_prop(bat, CFSTR("CurrentCapacity"), &cur);
    bool ok2 = _get_int_prop(bat, CFSTR("AppleRawMaxCapacity"), &mx) ||
               _get_int_prop(bat, CFSTR("MaxCapacity"), &mx);
    (void)_get_int_prop(bat, CFSTR("DesignCapacity"), &dsg);
    bool ok4 = _get_bool_prop(bat, CFSTR("ExternalConnected"), &ac);
    IOObjectRelease(bat);

    if (ok1 && ok2 && ok4) {
        if (current) *current = cur;
        if (max)     *max     = mx;
        if (design)  *design  = dsg;
        if (on_ac)   *on_ac   = ac;
        ok = true;
    }
    return ok;
}


bool is_on_ac_power(bool *on_ac) {
    bool ok, ac;
    
    io_registry_entry_t bat = _open_battery();
    if (bat == IO_OBJECT_NULL) {
        return false;
    }
    ok = _get_bool_prop(bat, CFSTR("ExternalConnected"), &ac);
    IOObjectRelease(bat);

    if (ok && on_ac) {
        *on_ac = ac;
    }
    return ok;
}


// int main(void) {
//     bool ac;
//     int cur=0, mx=0, dsg=0;

//     if (is_on_ac_power(&ac)) {
//         printf("AC power: %s\n", ac ? "yes" : "no");
//     } else {
//         printf("AC power: N/A\n");
//     }

//     if (get_battery_stats(&cur, &mx, &dsg, &ac)) {
//         printf("AC power: %s\n", ac ? "yes" : "no");
//         printf("Current=%d mAh, Max=%d mAh, Design=%d mAh\n", cur, mx, dsg);
//         if (mx > 0)   printf("SOC = %.1f%%\n", 100.0*cur/mx);
//         if (dsg > 0)  printf("SOH = %.1f%%\n", 100.0*mx/dsg);
//     } else {
//         printf("AC power: N/A\n");
//         fprintf(stderr, "Battery not found or properties unavailable\n");
//         return 1;
//     }
//     return 0;
// }


struct State {
    long last_check;
    long SLEEP_THRESHOLD;
    long INTERVAL;
    long start_time;
    long start_battery;
    long start_capacity;
    long sleep_time;
};

static bool parse_ll(const char *s, long *out) {
    if (!s) return false;
    errno = 0;
    char *end = NULL;
    long v = strtoll(s, &end, 10);
    if (errno || end == s) return false;
    *out = v;
    return true;
}

static bool load_state(const char *path, struct State *st) {
    FILE *f = fopen(path, "r");
    if ( ! f) return false;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!*line || line[0] == '#') {
            continue;
        }
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        const char *key = line;
        const char *val = eq + 1;

        long tmp = 0;
        if (strcmp(key, "last_check") == 0 && parse_ll(val, &tmp)) {
            st->last_check = tmp;
        } else if (strcmp(key, "SLEEP_THRESHOLD") == 0 && parse_ll(val, &tmp)) {
            st->SLEEP_THRESHOLD = tmp;
        } else if (strcmp(key, "INTERVAL") == 0 && parse_ll(val, &tmp)) {
            st->INTERVAL = tmp;
        } else if (strcmp(key, "start_time") == 0 && parse_ll(val, &tmp)) {
            st->start_time = tmp;
        } else if (strcmp(key, "start_battery") == 0 && parse_ll(val, &tmp)) {
            st->start_battery = tmp;
        } else if (strcmp(key, "start_capacity") == 0 && parse_ll(val, &tmp)) {
            st->start_capacity = tmp;
        } else if (strcmp(key, "sleep_time") == 0 && parse_ll(val, &tmp)) {
            st->sleep_time = tmp;
        }
    }
    fclose(f);
    return true;
}

static bool save_state_file(const char *path, const struct State *st) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return false;

    fprintf(f,
        "SLEEP_THRESHOLD=%ld\n"
        "INTERVAL=%ld\n"
        "start_time=%ld\n"
        "start_battery=%ld\n"
        "start_capacity=%ld\n"
        "sleep_time=%ld\n"
        "last_check=%ld\n",
        st->SLEEP_THRESHOLD,
        st->INTERVAL,
        st->start_time,
        st->start_battery,
        st->start_capacity,
        st->sleep_time,
        st->last_check
    );

    fclose(f);
    return rename(tmp, path) == 0;
}

static void apply_env_defaults(struct State *st) {
    st->INTERVAL = 5;
    st->SLEEP_THRESHOLD = 10;

    const char *e;
    long v;
    e = getenv("INTERVAL");
    if (e && *e && parse_ll(e, &v) && v > 0) {
        st->INTERVAL = v;
        st->SLEEP_THRESHOLD = st->INTERVAL * 2;
    }
    e = getenv("SLEEP_THRESHOLD");
    if (e && *e && parse_ll(e, &v) && v > 0) {
        st->SLEEP_THRESHOLD = v;
    }
}

static const char *get_state_path(void) {
    const char *env = getenv("STATE_FILE");
    if (env && *env) return env;
    
    static char path[512];
    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pw = getpwuid(getuid());
        if (pw && pw->pw_dir) home = pw->pw_dir;
    }
    if (!home) home = ".";
    snprintf(path, sizeof(path), "%s/%s", home, ".battery_tracker_state");
    return path;
}

static void format_time_hms(long seconds, char *buf, size_t n) {
    if (seconds < 0) seconds = 0;
    long h = seconds / 3600;
    long m = (seconds % 3600) / 60;
    long s = seconds % 60;
    if (h > 0) {
        snprintf(buf, n, "%ld:%02ld:%02ld", h, m, s);
    } else if (m > 0) {
        snprintf(buf, n, "%02ld:%02ld", m, s);
    } else {
        snprintf(buf, n, "%lds", s);
    }
}


static void monitor(const char *state_file) {
    struct State st = {0};

    if ( ! load_state(state_file, &st)) {
        st.last_check = (long)time(NULL);
    }
    // Trust INTERVAL from the env
    apply_env_defaults(&st);

    printf("Battery tracker started\n");

    while (1) {
        long current_time = (long)time(NULL);
        long elapsed = current_time - st.last_check;
        if (elapsed > st.SLEEP_THRESHOLD) {
            st.sleep_time += elapsed - st.INTERVAL;
        }

        bool on_ac;
        (void)is_on_ac_power(&on_ac);

        if (on_ac) {
            // Подключили к зарядке
            if (st.start_time != 0) {
                long total_time  = current_time - st.start_time;
                long active_time = total_time - st.sleep_time;

                int current_capacity = 0;
                int max_capacity = 0;
                (void)get_battery_stats(&current_capacity, &max_capacity, NULL, NULL);
                int current_battery = 100.0 * current_capacity / max_capacity;

                char active_buf[64];
                format_time_hms(active_time, active_buf, sizeof(active_buf));
                printf("Plugged: Active %s, Used %ld%% %ldmAh\n",
                       active_buf,
                       (st.start_battery - (long)current_battery),
                       (st.start_capacity - (long)current_capacity));

                // Сброс сессии и файла
                st.start_time = 0;
                st.start_battery = 0;
                st.start_capacity = 0;
                st.sleep_time = 0;
                unlink(state_file);
            }
        } else {
            // От батареи
            if (st.start_time == 0) {
                int current_capacity = 0;
                int max_capacity = 0;
                (void)get_battery_stats(&current_capacity, &max_capacity, NULL, NULL);
                int current_battery = 100.0 * current_capacity / max_capacity;

                st.start_time = current_time;
                st.start_battery  = current_battery;
                st.start_capacity = current_capacity;
                st.sleep_time = 0;
                printf("Unplugged: %ld%% %ldmAh\n", st.start_battery, st.start_capacity);
            }

            // Обновить last_check и сохранить весь state атомарно
            st.last_check = current_time;
            (void)save_state_file(state_file, &st);
        }

        st.last_check = current_time;
        sleep((unsigned)st.INTERVAL);
    }
}

static void show_status(const char *state_file) {
    struct State st = {0};
    apply_env_defaults(&st);

    // Trust INTERVAL from the state file
    if ( ! load_state(state_file, &st)) {
        printf("\033[2KNo active battery session\n");
        return;
    }

    int current_capacity = 0;
    int max_capacity = 0;
    (void)get_battery_stats(&current_capacity, &max_capacity, NULL, NULL);
    int current_battery = 100.0 * current_capacity / max_capacity;

    long current_time = (long)time(NULL);
    long elapsed = current_time - st.last_check;
    if (elapsed > st.SLEEP_THRESHOLD) {
        st.sleep_time += elapsed - st.INTERVAL;
    }
    long active_time = current_time - st.start_time - st.sleep_time;

    char active_buf[64], sleep_buf[64];
    format_time_hms(active_time, active_buf, sizeof(active_buf));
    format_time_hms(st.sleep_time, sleep_buf, sizeof(sleep_buf));

    printf("\033[2KActive time: %s (%s sleep)\n", active_buf, sleep_buf);
    printf("\033[2KBattery used: %ld%% %ldmAh (%d%% %dmAh current)\n",
           st.start_battery - current_battery,
           st.start_capacity - current_capacity,
           current_battery, current_capacity);
}

static void watch(int interval, const char *state_file) {
    while (1) {
        printf("\033[H");   // tput cup 0 0
        show_status(state_file);
        printf("\033[J");   // tput ed
        fflush(stdout);
        sleep(interval);
    }
}

static void show_help(const char *progname) {
    printf("Battery Active Time Tracker\n\n");
    printf("Usage: %s {monitor|status|watch}\n\n", progname);
    printf("Commands:\n");
    printf("  monitor  - Start monitoring battery sessions\n");
    printf("  status   - Show current session statistics\n");
    printf("  watch    - Show current session statistics in loop\n\n");
    printf("The tracker measures active (non-sleep) time while on battery\n");
    printf("and reports battery usage when you plug back in.\n");
}


int main(int argc, char *argv[]) {
    if (argc < 2) {
        show_help(argv[0]);
        return 1;
    }

    const char *STATE_FILE = get_state_path();

    if (strcmp(argv[1], "monitor") == 0) {
        monitor(STATE_FILE);
    } else if (strcmp(argv[1], "status") == 0) {
        show_status(STATE_FILE);
    } else if (strcmp(argv[1], "watch") == 0) {
        int interval = 5;
        if (argc > 2) {
            interval = atoi(argv[2]);
        }
        if (interval <= 0) {
            interval = 5;
        }
        watch(interval, STATE_FILE);
    } else {
        show_help(argv[0]);
        return 1;
    }

    return 0;
}
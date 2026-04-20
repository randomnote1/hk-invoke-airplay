/*
 * invoke-ctl — Control daemon for HK Invoke AirPlay speaker
 *
 * Maps physical controls to audio actions:
 *   - Volume dial (capacitive touch ring) → ALSA "music" volume
 *   - Tap on touch surface → play/pause (via shairport-sync DACP)
 *   - Double-tap → next track
 *   - Long press → mute toggle
 *   - Back button (GPIO) → AirPlay toggle / safe shutdown
 *
 * Input events are read from /dev/input/eventN (identified during calibration).
 * ALSA volume is controlled via the "music" softvol mixer on card 0.
 *
 * Build:
 *   arm-linux-gnueabihf-gcc -O2 -march=armv7-a -mfpu=neon -mfloat-abi=hard \
 *     -o invoke-ctl invoke-ctl.c -lpthread -lasound
 *
 * Usage:
 *   invoke-ctl [--input /dev/input/event0] [--mixer music] [--card 0]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/select.h>

/* ---------- Configuration (overridden by calibration data) ---------- */

/* Default input device — will be determined via getevent calibration */
#define DEFAULT_INPUT_DEV "/dev/input/event0"

/* ALSA mixer control name for music volume */
#define DEFAULT_MIXER_NAME "music"
#define DEFAULT_CARD 0

/* Volume step per dial tick (percentage points, 0-100) */
#define VOLUME_STEP 3

/* Tap timing thresholds (milliseconds) */
#define TAP_MAX_DURATION_MS 300
#define DOUBLE_TAP_WINDOW_MS 400
#define LONG_PRESS_MS 1000

/* shairport-sync DACP pipe for remote control */
#define SHAIRPORT_PIPE "/tmp/shairport-sync-pipe"

/* ---------- Globals ---------- */

static volatile int running = 1;
static int current_volume = 50; /* 0-100 */
static int muted = 0;
static int pre_mute_volume = 50;

/* Input event codes — populated during calibration */
static int dial_event_type = EV_ABS;  /* EV_ABS or EV_REL */
static int dial_event_code = 0;       /* ABS_X, REL_DIAL, etc. */
static int tap_event_code = 0;        /* BTN_TOUCH, KEY_*, etc. */
static int button_event_code = 0;     /* Back button key code */

/* ---------- Signal handling ---------- */

static void handle_signal(int sig) {
    (void)sig;
    running = 0;
}

/* ---------- ALSA volume control (via tinymix shell-out) ---------- */
/*
 * The stock rootfs includes tinymix but not full libasound headers.
 * We shell out to tinymix for simplicity. If we cross-compile with
 * libasound, we can switch to direct ALSA mixer API calls.
 */

static void set_volume(int vol) {
    char cmd[128];
    if (vol < 0) vol = 0;
    if (vol > 100) vol = 100;
    current_volume = vol;

    /* tinymix uses 0-255 range for softvol controls */
    int hw_vol = (vol * 255) / 100;
    snprintf(cmd, sizeof(cmd), "tinymix '%s' %d 2>/dev/null", DEFAULT_MIXER_NAME, hw_vol);
    system(cmd);
}

static void toggle_mute(void) {
    if (muted) {
        set_volume(pre_mute_volume);
        muted = 0;
        fprintf(stderr, "[invoke-ctl] unmuted, volume=%d%%\n", current_volume);
    } else {
        pre_mute_volume = current_volume;
        set_volume(0);
        muted = 1;
        fprintf(stderr, "[invoke-ctl] muted\n");
    }
}

/* ---------- shairport-sync DACP remote control ---------- */
/*
 * shairport-sync supports run-on-event scripts and a metadata pipe.
 * For DACP remote commands (play/pause/next), we use the built-in
 * D-Bus interface or write to the metadata pipe.
 *
 * Alternative: use shairport-sync's --get-coverart and MPRIS D-Bus
 * interface for richer control.
 */

static void send_dacp_command(const char *command) {
    char cmd[256];
    /* Use shairport-sync's command interface */
    snprintf(cmd, sizeof(cmd),
        "dbus-send --system --type=method_call "
        "--dest=org.gnome.ShairportSync "
        "/org/gnome/ShairportSync "
        "org.gnome.ShairportSync.RemoteControl.%s 2>/dev/null || true",
        command);
    system(cmd);
    fprintf(stderr, "[invoke-ctl] DACP: %s\n", command);
}

static void play_pause(void) {
    send_dacp_command("PlayPause");
}

static void next_track(void) {
    send_dacp_command("Next");
}

/* ---------- LED feedback (via mcu-interface) ---------- */
/*
 * The stock mcu-interface binary listens on 127.0.0.1:9999.
 * We can send commands to control the LED ring.
 * LED protocol TBD — will be reverse-engineered during device probing.
 */

/* ---------- Timestamp helpers ---------- */

static long long timespec_ms(struct timespec *ts) {
    return (long long)ts->tv_sec * 1000 + ts->tv_nsec / 1000000;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return timespec_ms(&ts);
}

/* ---------- Input event processing ---------- */

static void process_dial(struct input_event *ev) {
    if (ev->type != dial_event_type || ev->code != dial_event_code)
        return;

    int delta = 0;
    if (dial_event_type == EV_REL) {
        /* Relative dial: value is delta */
        delta = ev->value > 0 ? VOLUME_STEP : -VOLUME_STEP;
    } else if (dial_event_type == EV_ABS) {
        /* Absolute position: compute delta from last */
        static int last_abs = -1;
        if (last_abs >= 0) {
            delta = (ev->value - last_abs) * VOLUME_STEP;
            if (delta > VOLUME_STEP) delta = VOLUME_STEP;
            if (delta < -VOLUME_STEP) delta = -VOLUME_STEP;
        }
        last_abs = ev->value;
    }

    if (delta != 0) {
        if (muted && delta > 0) {
            muted = 0;
            current_volume = pre_mute_volume;
        }
        set_volume(current_volume + delta);
        fprintf(stderr, "[invoke-ctl] volume=%d%%\n", current_volume);
    }
}

static void process_tap(struct input_event *ev) {
    static long long last_tap_time = 0;
    static long long press_start = 0;
    static int press_active = 0;

    if (ev->type != EV_KEY)
        return;

    if (ev->code == tap_event_code) {
        if (ev->value == 1) {
            /* Key down */
            press_start = now_ms();
            press_active = 1;
        } else if (ev->value == 0 && press_active) {
            /* Key up */
            long long duration = now_ms() - press_start;
            press_active = 0;

            if (duration >= LONG_PRESS_MS) {
                /* Long press → mute toggle */
                toggle_mute();
            } else if (duration <= TAP_MAX_DURATION_MS) {
                /* Short tap */
                long long since_last = now_ms() - last_tap_time;
                if (since_last <= DOUBLE_TAP_WINDOW_MS && last_tap_time > 0) {
                    /* Double tap → next track */
                    next_track();
                    last_tap_time = 0; /* reset */
                } else {
                    last_tap_time = now_ms();
                    /* Delay play/pause to wait for possible double-tap */
                    usleep(DOUBLE_TAP_WINDOW_MS * 1000);
                    if (last_tap_time > 0) {
                        /* No second tap arrived → single tap = play/pause */
                        play_pause();
                        last_tap_time = 0;
                    }
                }
            }
        }
    }

    if (ev->code == button_event_code && ev->value == 1) {
        /* Back button pressed → safe shutdown */
        fprintf(stderr, "[invoke-ctl] back button pressed — shutting down\n");
        system("sync && reboot");
    }
}

/* ---------- Main loop ---------- */

int main(int argc, char *argv[]) {
    const char *input_dev = DEFAULT_INPUT_DEV;

    /* Parse args */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--input") == 0 && i + 1 < argc)
            input_dev = argv[++i];
        else if (strcmp(argv[i], "--help") == 0) {
            printf("Usage: invoke-ctl [--input /dev/input/eventN]\n");
            return 0;
        }
    }

    /* Signal handlers */
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    /* Open input device */
    int fd = open(input_dev, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "[invoke-ctl] Failed to open %s: %s\n",
                input_dev, strerror(errno));
        return 1;
    }

    /* Get device name */
    char name[256] = "Unknown";
    ioctl(fd, EVIOCGNAME(sizeof(name)), name);
    fprintf(stderr, "[invoke-ctl] Listening on %s: %s\n", input_dev, name);

    /* Set initial volume */
    set_volume(current_volume);

    /* Event loop */
    struct input_event ev;
    while (running) {
        fd_set rfds;
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };

        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);

        int ret = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ret == 0) continue; /* timeout, just loop */

        if (read(fd, &ev, sizeof(ev)) != sizeof(ev))
            continue;

        process_dial(&ev);
        process_tap(&ev);
    }

    close(fd);
    fprintf(stderr, "[invoke-ctl] exiting\n");
    return 0;
}

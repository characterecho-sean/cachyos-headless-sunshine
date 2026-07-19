/* Vendored from https://gitlab.com/amini-allight/gamepad-clone (GPL-3.0-or-later,
 * see LICENSE in this directory), commit 8833f8b, with two local patches:
 *
 * 1. `input_file` is now opened without O_NONBLOCK. Upstream's run_device()
 *    loop has no select()/poll() around its non-blocking read(), so on an
 *    idle gamepad it was spinning at 100% of one CPU core continuously --
 *    unacceptable on a real-time game-streaming rig where CPU contention
 *    directly causes dropped/corrupted encoder frames (see this repo's
 *    cap_sys_nice fix for sunshine). A blocking read() fixes this with no
 *    behavior change otherwise.
 * 2. The cloned device's name gets a " (uinput-clone)" suffix instead of
 *    being copied verbatim. This repo's udev rule matches Sunshine's
 *    virtual Xbox pad by name to auto-launch this driver -- without a
 *    distinct name, the clone this driver creates would itself match that
 *    same rule and spawn a clone-of-a-clone, recursively, until the box
 *    runs out of input device slots.
 *
 * Only fix for: Star Wars Outlaws / Avatar: Frontiers of Pandora (and
 * likely other Snowdrop-engine Ubisoft titles) not detecting Sunshine's
 * virtual Xbox controller -- see README Troubleshooting.
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <linux/input.h>
#include <linux/uinput.h>

static const char* const search_directory_path = "/dev/input";
static const char* const output_path = "/dev/uinput";
static const char* const clone_name_suffix = " (uinput-clone)";
static int input_file = -1;
static int output_file = -1;
static int quit = 0;

static int get_bit(unsigned char* data, int index)
{
    return data[index / 8] & (1 << (index % 8));
}

static int init_device()
{
    int error;

    struct uinput_setup device;
    memset(&device, 0, sizeof(device));

    device.ff_effects_max = 32;

    error = ioctl(input_file, EVIOCGID, &device.id);

    if (error < 0)
    {
        fprintf(stderr, "failed to query input ID: %i\n", errno);
        return error;
    }

    error = ioctl(input_file, EVIOCGNAME(sizeof(device.name) - 1), device.name);

    if (error < 0)
    {
        fprintf(stderr, "failed to query input name: %i\n", errno);
        return error;
    }

    /* Ensure NUL-termination, then append clone_name_suffix (truncating the
     * copied name first if there isn't room) -- see file header comment. */
    {
        size_t max_len = sizeof(device.name) - 1;
        size_t suffix_len = strlen(clone_name_suffix);
        size_t name_len;

        device.name[max_len] = '\0';
        name_len = strlen(device.name);

        if (name_len + suffix_len > max_len)
        {
            name_len = max_len > suffix_len ? max_len - suffix_len : 0;
        }

        memcpy(device.name + name_len, clone_name_suffix, suffix_len + 1);
    }

    unsigned char events[EV_MAX];
    memset(events, 0, sizeof(events));
    error = ioctl(input_file, EVIOCGBIT(0, EV_MAX), events);

    if (error < 0)
    {
        fprintf(stderr, "failed to query input events: %i\n", errno);
        return error;
    }

    int i;
    for (i = 0; i < EV_MAX; i++)
    {
        /* HACK: removes haptics to get it working, no idea why this is required */
        if (i == EV_FF)
        {
            continue;
        }

        if (get_bit(events, i))
        {
            error = ioctl(output_file, UI_SET_EVBIT, i);

            if (error < 0)
            {
                fprintf(stderr, "failed to set event: %i\n", errno);
                return error;
            }
        }

        switch (i)
        {
        case EV_KEY :
        {
            unsigned char keys[KEY_MAX];
            memset(keys, 0, sizeof(keys));
            error = ioctl(input_file, EVIOCGBIT(EV_KEY, KEY_MAX), keys);

            if (error < 0)
            {
                fprintf(stderr, "failed to query input keys: %i\n", errno);
                return error;
            }

            int j;
            for (j = 0; j < KEY_MAX; j++)
            {
                if (get_bit(keys, j))
                {
                    error = ioctl(output_file, UI_SET_KEYBIT, j);

                    if (error < 0)
                    {
                        fprintf(stderr, "failed to set key: %i\n", errno);
                        return error;
                    }
                }
            }
            break;
        }
        case EV_ABS :
        {
            unsigned char abs[ABS_MAX];
            memset(abs, 0, sizeof(abs));
            error = ioctl(input_file, EVIOCGBIT(EV_ABS, ABS_MAX), abs);

            if (error < 0)
            {
                fprintf(stderr, "failed to query input absolutes: %i\n", errno);
                return error;
            }

            int j;
            for (j = 0; j < ABS_MAX; j++)
            {
                if (get_bit(abs, j))
                {
                    error = ioctl(output_file, UI_SET_ABSBIT, j);

                    if (error < 0)
                    {
                        fprintf(stderr, "failed to set absolute: %i\n", errno);
                        return error;
                    }

                    struct uinput_abs_setup setup;
                    memset(&setup, 0, sizeof(setup));

                    setup.code = j;
                    error = ioctl(input_file, EVIOCGABS(j), &setup.absinfo);

                    if (error < 0)
                    {
                        fprintf(stderr, "failed to query input absolute info: %i\n", errno);
                        return error;
                    }

                    error = ioctl(output_file, UI_ABS_SETUP, &setup);

                    if (error < 0)
                    {
                        fprintf(stderr, "failed to set absolute info: %i\n", errno);
                        return error;
                    }
                }
            }
            break;
        }
        case EV_FF :
        {
            unsigned char ffs[FF_MAX];
            memset(ffs, 0, sizeof(ffs));
            error = ioctl(input_file, EVIOCGBIT(EV_FF, FF_MAX), ffs);

            if (error < 0)
            {
                fprintf(stderr, "failed to query input force feedbacks: %i\n", errno);
                return error;
            }

            int j;
            for (j = 0; j < FF_MAX; j++)
            {
                if (get_bit(ffs, j))
                {
                    error = ioctl(output_file, UI_SET_FFBIT, j);

                    if (error < 0)
                    {
                        fprintf(stderr, "failed to set force feedback: %i\n", errno);
                        return error;
                    }
                }
            }
            break;
        }
        }
    }

    error = ioctl(output_file, UI_DEV_SETUP, &device);

    if (error < 0)
    {
        fprintf(stderr, "failed to write to uinput handle: %i\n", errno);
        return error;
    }

    error = ioctl(output_file, UI_DEV_CREATE);

    if (error < 0)
    {
        fprintf(stderr, "failed to create uinput device: %i\n", errno);
        return error;
    }

    return 0;
}

static int destroy_device()
{
    int error = ioctl(output_file, UI_DEV_DESTROY);

    if (error < 0)
    {
        fprintf(stderr, "failed to destroy uinput device: %i\n", errno);
        return error;
    }

    return 0;
}

static void on_signal(int signal)
{
    quit = 1;
}

static void run_device()
{
    int result;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    fprintf(stdout, "driver ready\n");

    while (!quit)
    {
        struct input_event event;

        result = read(input_file, &event, sizeof(event));

        if (result < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }

            fprintf(stderr, "read fail: %i\n", errno);
            break;
        }

        if (result < (int) sizeof(event))
        {
            fprintf(stderr, "read fail\n");
            continue;
        }

        result = write(output_file, &event, sizeof(event));

        if (result < (int) sizeof(event))
        {
            fprintf(stderr, "write fail\n");
        }
    }
}

static char* find_input_path()
{
    int error;

    DIR* directory = opendir(search_directory_path);

    if (!directory)
    {
        fprintf(stderr, "failed to open search directory '%s': %i\n", search_directory_path, errno);
        return NULL;
    }

    int directory_file = dirfd(directory);

    if (directory_file < 0)
    {
        fprintf(stderr, "failed to get search directory file descriptor: %i\n", errno);
        closedir(directory);
        return NULL;
    }

    struct dirent* directory_entry = NULL;

    char* result = NULL;

    while ((directory_entry = readdir(directory)) != NULL)
    {
        int file = openat(directory_file, directory_entry->d_name, O_RDWR);

        if (file < 0)
        {
            continue;
        }

        unsigned char abs[ABS_MAX];
        error = ioctl(file, EVIOCGBIT(EV_ABS, ABS_MAX), abs);

        if (error < 0)
        {
            close(file);
            continue;
        }

        error = close(file);

        if (error)
        {
            fprintf(stderr, "failed to close search file '%s/%s': %i\n", search_directory_path, directory_entry->d_name, errno);
            continue;
        }

        if (get_bit(abs, ABS_RZ))
        {
            result = malloc(strlen(search_directory_path) + strlen(directory_entry->d_name) + 2);
            strcpy(result, search_directory_path);
            strcpy(result + strlen(search_directory_path), "/");
            strcpy(result + strlen(search_directory_path) + 1, directory_entry->d_name);
            strcpy(result + strlen(search_directory_path) + 1 + strlen(directory_entry->d_name), "\0");
            break;
        }
    }

    error = closedir(directory);

    if (error)
    {
        fprintf(stderr, "failed to close search directory '%s': %i\n", search_directory_path, errno);
        return NULL;
    }

    return result;
}

int main(int argc, char** argv)
{
    int error;

    if (argc != 1 && argc != 2)
    {
        fprintf(stderr, "usage: %s [input-path]\n", argv[0]);
        return 1;
    }

    char* input_path = argc == 2 ? strdup(argv[1]) : find_input_path();

    if (!input_path)
    {
        fprintf(stderr, "failed to find input file\n");
        return 1;
    }

    fprintf(stdout, "using device at '%s'\n", input_path);

    input_file = open(input_path, O_RDWR);

    if (input_file < 0)
    {
        fprintf(stderr, "failed to open file '%s', %i\n", input_path, errno);
        free(input_path);
        return 1;
    }

    output_file = open(output_path, O_WRONLY | O_NONBLOCK);

    if (output_file < 0)
    {
        fprintf(stderr, "failed to open file '%s', %i\n", output_path, errno);
        free(input_path);
        close(input_file);
        return 1;
    }

    error = init_device();

    if (error)
    {
        fprintf(stderr, "failed to initialize device: %i\n", error);
        free(input_path);
        close(output_file);
        close(input_file);
        return 1;
    }

    run_device();

    error = destroy_device();

    if (error)
    {
        fprintf(stderr, "failed to destroy device: %i\n", error);
        free(input_path);
        close(output_file);
        close(input_file);
        return 1;
    }

    error = close(output_file);

    if (error)
    {
        fprintf(stderr, "failed to close file '%s': %i\n", output_path, errno);
        free(input_path);
        close(input_file);
        return 1;
    }

    error = close(input_file);

    if (error)
    {
        fprintf(stderr, "failed to close file '%s': %i\n", input_path, errno);
        free(input_path);
        return 1;
    }

    free(input_path);

    return 0;
}

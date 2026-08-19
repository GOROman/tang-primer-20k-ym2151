// Dump timed YM2151 and X68000 ADPCM events from an MDX/PDX pair.
// Output: time_us F reg value
//         time_us P sample frequency volume pan
//         time_us S channel
//         time_us V channel volume
//         time_us R channel frequency
//         time_us A pan
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "tools.h"
#include "mdx.h"
#include "pdx.h"
#include "mdx_driver.h"
#include "pcm_timer_driver.h"
#include "fm_opm_driver.h"
#include "adpcm_driver.h"

#define EVENT_RATE 1000000
#define MAX_SECONDS 300

static uint64_t now_samples;
static struct pdx_file *loaded_pdx;

static unsigned long long now_us(void) {
    return (unsigned long long)(now_samples * 1000000ULL / EVENT_RATE);
}

static int sample_index(uint8_t *data) {
    for (int i = 0; i < PDX_NUM_SAMPLES; ++i)
        if (loaded_pdx->samples[i].data == data)
            return i;
    return -1;
}

static void fm_write(struct fm_opm_driver *driver, uint8_t reg, uint8_t value) {
    (void)driver;
    printf("%llu F %u %u\n", now_us(), reg, value);
}

static int adpcm_play_cb(struct adpcm_driver *driver, uint8_t channel,
                         uint8_t *data, int len, uint8_t freq, uint8_t volume) {
    int index = sample_index(data);
    if (index < 0) {
        fprintf(stderr, "unknown PDX sample pointer\n");
        return -1;
    }
    printf("%llu P %d %u %u %u %d\n", now_us(), index, freq, volume,
           driver->pan, len);
    return 0;
}

static int adpcm_stop_cb(struct adpcm_driver *driver, uint8_t channel) {
    (void)driver;
    printf("%llu S %u\n", now_us(), channel);
    return 0;
}

static int adpcm_volume_cb(struct adpcm_driver *driver, uint8_t channel,
                           uint8_t volume) {
    (void)driver;
    printf("%llu V %u %u\n", now_us(), channel, volume);
    return 0;
}

static int adpcm_freq_cb(struct adpcm_driver *driver, uint8_t channel,
                         uint8_t freq) {
    (void)driver;
    printf("%llu R %u %u\n", now_us(), channel, freq);
    return 0;
}

static int adpcm_pan_cb(struct adpcm_driver *driver, uint8_t pan) {
    printf("%llu A %u\n", now_us(), pan);
    driver->pan = pan;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s song.mdx samples.pdx\n", argv[0]);
        return 2;
    }

    size_t mdx_size = 0, pdx_size = 0;
    uint8_t *mdx_data = load_file(argv[1], &mdx_size);
    uint8_t *pdx_data = load_file(argv[2], &pdx_size);
    if (!mdx_data || !pdx_data) {
        fprintf(stderr, "failed to read MDX/PDX\n");
        return 1;
    }

    struct mdx_file mdx;
    struct pdx_file pdx;
    if (mdx_file_load(&mdx, mdx_data, mdx_size) ||
        pdx_file_load(&pdx, pdx_data, pdx_size)) {
        fprintf(stderr, "failed to parse MDX/PDX\n");
        return 1;
    }
    loaded_pdx = &pdx;

    struct pcm_timer_driver timer = {0};
    struct fm_opm_driver fm = {0};
    struct adpcm_driver adpcm = {0};
    struct mdx_driver player = {0};
    pcm_timer_driver_init(&timer, EVENT_RATE);
    fm_opm_driver_init(&fm, NULL);
    fm.write = fm_write;
    adpcm_driver_init(&adpcm);
    adpcm.play = adpcm_play_cb;
    adpcm.stop = adpcm_stop_cb;
    adpcm.set_volume = adpcm_volume_cb;
    adpcm.set_freq = adpcm_freq_cb;
    adpcm.set_pan = adpcm_pan_cb;
    mdx_driver_init(&player, (struct timer_driver *)&timer,
                    (struct fm_driver *)&fm, &adpcm);
    mdx_driver_load(&player, &mdx, &pdx);
    player.max_loops = 1;

    while (!player.ended && now_samples < (uint64_t)MAX_SECONDS * EVENT_RATE) {
        int samples = pcm_timer_driver_estimate(&timer, EVENT_RATE);
        now_samples += samples;
        pcm_timer_driver_advance(&timer, samples);
    }

    fprintf(stderr, "duration %.6f s\n", (double)now_samples / EVENT_RATE);
    return player.ended ? 0 : 1;
}

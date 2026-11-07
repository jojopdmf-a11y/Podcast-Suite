#include "lame_dynamic.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *lame_t;
typedef int (*fn_set_int)(lame_t, int);
typedef int (*fn_set_ulong)(lame_t, unsigned long);
typedef void (*fn_set_void_int)(lame_t, int);
typedef int (*fn_init_params)(lame_t);
typedef int (*fn_encode_float)(lame_t, const float *, const float *, int, unsigned char *, int);
typedef int (*fn_encode_interleaved)(lame_t, const float *, int, unsigned char *, int);
typedef int (*fn_flush)(lame_t, unsigned char *, int);
typedef size_t (*fn_lametag)(const void *, unsigned char *, size_t);
typedef int (*fn_close)(lame_t);
typedef lame_t (*fn_init)(void);
typedef void (*lame_report_fn)(const char *, va_list);
typedef int (*fn_set_report)(lame_t, lame_report_fn);

struct LAMEAPI {
    void *handle;
    fn_init init;
    fn_set_int set_num_channels;
    fn_set_int set_in_samplerate;
    fn_set_int set_out_samplerate;
    fn_set_int set_brate;
    fn_set_int set_mode;
    fn_set_int set_vbr;
    fn_set_int set_write_tag;
    fn_set_void_int set_id3_automatic;
    fn_set_ulong set_num_samples;
    fn_set_report set_errorf;
    fn_set_report set_debugf;
    fn_set_report set_msgf;
    fn_init_params init_params;
    fn_encode_float encode_ieee_float;
    fn_encode_interleaved encode_interleaved_ieee_float;
    fn_flush encode_flush;
    fn_lametag get_lametag_frame;
    fn_close close;
};

struct LAMESession {
    lame_t gfp;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct LAMEAPI g_api;
static int g_ready = 0;
static char g_error[256] = "MP3 encoder is missing.";

static void set_error(const char *message) {
    snprintf(g_error, sizeof g_error, "%s", message);
}

static void lame_quiet(const char *format, va_list ap) {
    (void)format;
    (void)ap;
}

static int bind_symbol(void **slot, void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (symbol == NULL) {
        snprintf(g_error, sizeof g_error, "MP3 encoder is missing %s.", name);
        return -1;
    }
    *slot = symbol;
    return 0;
}

const char *lame_shim_last_error(void) {
    return g_error;
}

int lame_shim_open(const char *path) {
    if (path == NULL || path[0] == '\0') {
        set_error("MP3 encoder is missing.");
        return -1;
    }
    pthread_mutex_lock(&g_lock);
    if (g_ready) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *reason = dlerror();
        snprintf(g_error, sizeof g_error, "MP3 encoder is missing%s%s.",
                 reason ? ": " : "", reason ? reason : "");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    struct LAMEAPI api;
    memset(&api, 0, sizeof api);
    api.handle = handle;
    int failed = 0;
    failed |= bind_symbol((void **)&api.init, handle, "lame_init");
    failed |= bind_symbol((void **)&api.set_num_channels, handle, "lame_set_num_channels");
    failed |= bind_symbol((void **)&api.set_in_samplerate, handle, "lame_set_in_samplerate");
    failed |= bind_symbol((void **)&api.set_out_samplerate, handle, "lame_set_out_samplerate");
    failed |= bind_symbol((void **)&api.set_brate, handle, "lame_set_brate");
    failed |= bind_symbol((void **)&api.set_mode, handle, "lame_set_mode");
    failed |= bind_symbol((void **)&api.set_vbr, handle, "lame_set_VBR");
    failed |= bind_symbol((void **)&api.set_write_tag, handle, "lame_set_bWriteVbrTag");
    failed |= bind_symbol((void **)&api.set_id3_automatic, handle, "lame_set_write_id3tag_automatic");
    failed |= bind_symbol((void **)&api.set_num_samples, handle, "lame_set_num_samples");
    failed |= bind_symbol((void **)&api.set_errorf, handle, "lame_set_errorf");
    failed |= bind_symbol((void **)&api.set_debugf, handle, "lame_set_debugf");
    failed |= bind_symbol((void **)&api.set_msgf, handle, "lame_set_msgf");
    failed |= bind_symbol((void **)&api.init_params, handle, "lame_init_params");
    failed |= bind_symbol((void **)&api.encode_ieee_float, handle, "lame_encode_buffer_ieee_float");
    failed |= bind_symbol((void **)&api.encode_interleaved_ieee_float, handle, "lame_encode_buffer_interleaved_ieee_float");
    failed |= bind_symbol((void **)&api.encode_flush, handle, "lame_encode_flush");
    failed |= bind_symbol((void **)&api.get_lametag_frame, handle, "lame_get_lametag_frame");
    failed |= bind_symbol((void **)&api.close, handle, "lame_close");
    if (failed) {
        dlclose(handle);
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    g_api = api;
    g_ready = 1;
    g_error[0] = '\0';
    pthread_mutex_unlock(&g_lock);
    return 0;
}

static int require_ready(void) {
    if (g_ready) {
        return 0;
    }
    set_error("MP3 encoder is missing.");
    return -1;
}

LAMESession *lame_shim_begin(int channels, int sample_rate, int bitrate_kbps, unsigned long num_samples) {
    if (require_ready() != 0) {
        return NULL;
    }
    if (channels != 1 && channels != 2) {
        set_error("MP3 export supports mono or stereo.");
        return NULL;
    }
    lame_t gfp = g_api.init();
    if (gfp == NULL) {
        set_error("Could not start the MP3 encoder.");
        return NULL;
    }
    /* Silence LAME's own stderr report. Encode errors come back as status codes. */
    g_api.set_errorf(gfp, lame_quiet);
    g_api.set_debugf(gfp, lame_quiet);
    g_api.set_msgf(gfp, lame_quiet);
    /* MPEG_mode: JOINT_STEREO = 1, MONO = 3. vbr_off = 0. */
    int mode = channels == 1 ? 3 : 1;
    if (g_api.set_num_channels(gfp, channels) != 0
        || g_api.set_in_samplerate(gfp, sample_rate) != 0
        || g_api.set_out_samplerate(gfp, sample_rate) != 0
        || g_api.set_brate(gfp, bitrate_kbps) != 0
        || g_api.set_mode(gfp, mode) != 0
        || g_api.set_vbr(gfp, 0) != 0
        || g_api.set_write_tag(gfp, 1) != 0
        || g_api.set_num_samples(gfp, num_samples) != 0) {
        g_api.close(gfp);
        set_error("Could not configure the MP3 encoder.");
        return NULL;
    }
    g_api.set_id3_automatic(gfp, 0);
    if (g_api.init_params(gfp) < 0) {
        g_api.close(gfp);
        set_error("Could not start the MP3 encoder.");
        return NULL;
    }
    LAMESession *session = calloc(1, sizeof *session);
    if (session == NULL) {
        g_api.close(gfp);
        set_error("Out of memory.");
        return NULL;
    }
    session->gfp = gfp;
    return session;
}

void lame_shim_end(LAMESession *session) {
    if (session == NULL) {
        return;
    }
    if (session->gfp != NULL && g_ready) {
        g_api.close(session->gfp);
    }
    free(session);
}

int lame_shim_encode_mono(LAMESession *session, const float *pcm, int frames, unsigned char *out, int out_capacity) {
    if (session == NULL || session->gfp == NULL || pcm == NULL || out == NULL) {
        return -1;
    }
    return g_api.encode_ieee_float(session->gfp, pcm, NULL, frames, out, out_capacity);
}

int lame_shim_encode_stereo(LAMESession *session, const float *pcm, int frames, unsigned char *out, int out_capacity) {
    if (session == NULL || session->gfp == NULL || pcm == NULL || out == NULL) {
        return -1;
    }
    return g_api.encode_interleaved_ieee_float(session->gfp, pcm, frames, out, out_capacity);
}

int lame_shim_flush(LAMESession *session, unsigned char *out, int out_capacity) {
    if (session == NULL || session->gfp == NULL || out == NULL) {
        return -1;
    }
    return g_api.encode_flush(session->gfp, out, out_capacity);
}

size_t lame_shim_lametag(LAMESession *session, unsigned char *out, size_t out_capacity) {
    if (session == NULL || session->gfp == NULL) {
        return 0;
    }
    return g_api.get_lametag_frame(session->gfp, out, out_capacity);
}

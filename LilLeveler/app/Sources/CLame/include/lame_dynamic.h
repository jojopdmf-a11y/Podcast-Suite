#ifndef LAME_DYNAMIC_H
#define LAME_DYNAMIC_H

#include <stddef.h>

/* Runtime loader for libmp3lame. The app does not link LAME at build time.
 * Decode entry points are intentionally absent. */

typedef struct LAMESession LAMESession;

/// 0 when the library is loaded and every encode symbol resolved.
int lame_shim_open(const char *path);

const char *lame_shim_last_error(void);

/// NULL on failure. `bitrate_kbps` is constant bitrate. `num_samples` is
/// the number of PCM frames per channel.
LAMESession *lame_shim_begin(int channels, int sample_rate, int bitrate_kbps, unsigned long num_samples);

void lame_shim_end(LAMESession *session);

/// Bytes written, or a negative LAME status.
int lame_shim_encode_mono(LAMESession *session, const float *pcm, int frames, unsigned char *out, int out_capacity);
int lame_shim_encode_stereo(LAMESession *session, const float *pcm, int frames, unsigned char *out, int out_capacity);
int lame_shim_flush(LAMESession *session, unsigned char *out, int out_capacity);

/// Bytes of the LAME/Xing tag, the required size when `out` is too small, or 0.
size_t lame_shim_lametag(LAMESession *session, unsigned char *out, size_t out_capacity);

#endif

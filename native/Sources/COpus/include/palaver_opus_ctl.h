/* Palaver's own: the few opus_*_ctl requests the Swift side needs, as plain functions (Swift does not import C's
 * variadic functions). */
#ifndef PALAVER_OPUS_CTL_H
#define PALAVER_OPUS_CTL_H

#include "opus.h"

int palaver_opus_encoder_set_complexity(OpusEncoder *st, opus_int32 complexity);
int palaver_opus_encoder_get_lookahead(OpusEncoder *st, opus_int32 *lookahead);
int palaver_opus_decoder_set_gain(OpusDecoder *st, opus_int32 gain);

#endif

/* Palaver's own (see include/palaver_opus_ctl.h). */
#include "palaver_opus_ctl.h"

int palaver_opus_encoder_set_complexity(OpusEncoder *st, opus_int32 complexity) {
    return opus_encoder_ctl(st, OPUS_SET_COMPLEXITY(complexity));
}

int palaver_opus_encoder_get_lookahead(OpusEncoder *st, opus_int32 *lookahead) {
    return opus_encoder_ctl(st, OPUS_GET_LOOKAHEAD(lookahead));
}

int palaver_opus_decoder_set_gain(OpusDecoder *st, opus_int32 gain) {
    return opus_decoder_ctl(st, OPUS_SET_GAIN(gain));
}

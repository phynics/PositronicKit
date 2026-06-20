#ifndef PKFASTEMBED_H
#define PKFASTEMBED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PKFASTEMBED_ABI_VERSION 1U

typedef struct pkfe_model pkfe_model_t;

typedef enum pkfe_status {
    PKFE_STATUS_OK = 0,
    PKFE_STATUS_INVALID_ARGUMENT = 1,
    PKFE_STATUS_INVALID_UTF8 = 2,
    PKFE_STATUS_MODEL_LOAD_FAILED = 3,
    PKFE_STATUS_INFERENCE_FAILED = 4,
    PKFE_STATUS_BUFFER_TOO_SMALL = 5,
    PKFE_STATUS_ABI_MISMATCH = 6
} pkfe_status_t;

uint32_t pkfe_abi_version(void);

pkfe_status_t pkfe_model_create(
    const char *model_directory,
    pkfe_model_t **out_model,
    char **out_error_message
);

pkfe_status_t pkfe_model_dimensions(
    const pkfe_model_t *model,
    size_t *out_dimensions,
    char **out_error_message
);

pkfe_status_t pkfe_model_embed(
    pkfe_model_t *model,
    const uint8_t *utf8_bytes,
    size_t utf8_length,
    float *out_buffer,
    size_t out_count,
    char **out_error_message
);

pkfe_status_t pkfe_model_embed_batch(
    pkfe_model_t *model,
    const uint8_t *const *utf8_bytes,
    const size_t *utf8_lengths,
    size_t text_count,
    float *out_buffer,
    size_t out_count,
    char **out_error_message
);

void pkfe_model_destroy(pkfe_model_t *model);
void pkfe_string_destroy(char *value);

#ifdef __cplusplus
}
#endif

#endif

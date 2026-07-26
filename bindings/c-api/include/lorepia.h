#ifndef LOREPIA_H
#define LOREPIA_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(LOREPIA_BUILD_DLL)
#define LOREPIA_API __declspec(dllexport)
#else
#define LOREPIA_API __declspec(dllimport)
#endif
#define LOREPIA_CALL __cdecl
#else
#define LOREPIA_API
#define LOREPIA_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lorepia_core lorepia_core_t;

typedef struct lorepia_buffer {
    uint8_t *ptr;
    size_t len;
} lorepia_buffer_t;

enum lorepia_status {
    LOREPIA_OK = 0,
    LOREPIA_INVALID_ARGUMENT = 1,
    LOREPIA_NOT_FOUND = 2,
    LOREPIA_STORAGE_ERROR = 3,
    LOREPIA_INTERNAL_ERROR = 255
};

LOREPIA_API uint32_t LOREPIA_CALL lorepia_abi_version(void);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_create(
    const uint8_t *config_json,
    size_t config_len,
    lorepia_core_t **out_core
);
LOREPIA_API void LOREPIA_CALL lorepia_core_destroy(lorepia_core_t *core);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_version(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_health_check_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_characters_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API void LOREPIA_CALL lorepia_buffer_free(lorepia_buffer_t buffer);

#ifdef __cplusplus
}
#endif

#endif

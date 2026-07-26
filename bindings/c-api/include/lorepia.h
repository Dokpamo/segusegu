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

/*
 * A core handle is owned by the caller. Destroy it exactly once and do not
 * race any call with lorepia_core_destroy.
 */
typedef struct lorepia_core lorepia_core_t;

/*
 * Every non-empty returned buffer is owned by the caller and must be released
 * exactly once with lorepia_buffer_free.
 */
typedef struct lorepia_buffer {
    uint8_t *ptr;
    size_t len;
} lorepia_buffer_t;

enum lorepia_status {
    LOREPIA_OK = 0,
    LOREPIA_INVALID_ARGUMENT = 1,
    LOREPIA_UNSUPPORTED_CONTENT = 2,
    LOREPIA_UNSAFE_ARCHIVE = 3,
    LOREPIA_NOT_FOUND = 4,
    LOREPIA_PERMISSION_DENIED = 5,
    LOREPIA_STORAGE_UNAVAILABLE = 6,
    LOREPIA_STORAGE_CORRUPTED = 7,
    LOREPIA_PROVIDER_AUTH_FAILED = 8,
    LOREPIA_PROVIDER_RATE_LIMITED = 9,
    LOREPIA_PROVIDER_UNAVAILABLE = 10,
    LOREPIA_NETWORK_UNAVAILABLE = 11,
    LOREPIA_CANCELLED = 12,
    LOREPIA_INTERNAL_ERROR = 255
};

LOREPIA_API uint32_t LOREPIA_CALL lorepia_abi_version(void);

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_create(
    const uint8_t *config_json,
    size_t config_len,
    lorepia_core_t **out_core
);
LOREPIA_API void LOREPIA_CALL lorepia_core_destroy(lorepia_core_t *core);

/*
 * Returns the handle's last structured error as JSON. Pass NULL for core to
 * retrieve a create-time or null-handle error from the current thread.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_last_error_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_version(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_health_check_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);

/*
 * The inspection JSON includes representative_image as nullable
 * platform-neutral metadata (logical_asset_id, media_type, size_bytes) and a
 * bounded unsupported_optional_fields string array. It never exposes staged
 * paths or raw asset bytes.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_inspect_import_json(
    const lorepia_core_t *core,
    const uint8_t *staged_path,
    size_t staged_path_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_commit_import_json(
    const lorepia_core_t *core,
    const uint8_t *inspection_id,
    size_t inspection_id_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_discard_import(
    const lorepia_core_t *core,
    const uint8_t *inspection_id,
    size_t inspection_id_len
);

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_characters_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_character_json(
    const lorepia_core_t *core,
    const uint8_t *character_id,
    size_t character_id_len,
    lorepia_buffer_t *out_buffer
);

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_open_conversation_json(
    const lorepia_core_t *core,
    const uint8_t *character_id,
    size_t character_id_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_conversations_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_messages_json(
    const lorepia_core_t *core,
    const uint8_t *conversation_id,
    size_t conversation_id_len,
    lorepia_buffer_t *out_buffer
);

/*
 * credential_present must be 0 or 1. When it is 0, credential must be NULL
 * and credential_len must be zero.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_send_message_json(
    const lorepia_core_t *core,
    const uint8_t *conversation_id,
    size_t conversation_id_len,
    const uint8_t *text,
    size_t text_len,
    const uint8_t *provider_profile_id,
    size_t provider_profile_id_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_cancel_generation(
    const lorepia_core_t *core,
    const uint8_t *generation_id,
    size_t generation_id_len
);

/*
 * Returns {"events": [...], "dropped_events": N}. max_events must be between
 * 1 and 1024. Callers should refresh persisted messages when N is non-zero.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_poll_events_json(
    const lorepia_core_t *core,
    uint32_t max_events,
    lorepia_buffer_t *out_buffer
);

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_settings_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_update_settings_json(
    const lorepia_core_t *core,
    const uint8_t *settings_json,
    size_t settings_json_len
);

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_profiles_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_upsert_provider_profile_json(
    const lorepia_core_t *core,
    const uint8_t *profile_json,
    size_t profile_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_delete_provider_profile(
    const lorepia_core_t *core,
    const uint8_t *profile_id,
    size_t profile_id_len
);

LOREPIA_API void LOREPIA_CALL lorepia_buffer_free(lorepia_buffer_t buffer);

#ifdef __cplusplus
}
#endif

#endif

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
 * exactly once with lorepia_buffer_free. The free operation overwrites the
 * bytes before releasing the allocation so it is also the required disposal
 * path for transient credential buffers.
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

/*
 * ABI v4 request JSON uses this envelope:
 * {"request_schema_version":1,"payload":{...}}
 *
 * Raw credentials are never members of the JSON payload. They remain
 * request-scoped scalar inputs using the same present/null convention as the
 * legacy send function above.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_send_message_with_target_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_send_message_to_branch_with_target_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_edit_user_message_with_target_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_regenerate_assistant_message_with_target_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
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

LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_templates_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_create_provider_connection_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_connections_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
/*
 * Upsert accepts a versioned, secret-free DTO with credential_slot_ready and
 * approved_credential_origins. It never accepts credential_ref; Core derives
 * the opaque vault reference exactly from the immutable connection ID.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_upsert_provider_connection_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_delete_provider_connection_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_model_routes_json(
    const lorepia_core_t *core,
    const uint8_t *connection_id,
    size_t connection_id_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_upsert_model_route_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_delete_model_route_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_capability_observations_json(
    const lorepia_core_t *core,
    const uint8_t *model_route_id,
    size_t model_route_id_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_effective_capability_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_effective_parameter_specs_json(
    const lorepia_core_t *core,
    const uint8_t *model_route_id,
    size_t model_route_id_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_upsert_user_capability_override_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_delete_user_capability_override_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_refresh_provider_models_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_start_provider_model_sync_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_provider_model_sync_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_model_syncs_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_approve_provider_model_sync_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_cancel_provider_model_sync_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_poll_provider_model_sync_job_events_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_ack_provider_model_sync_event_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);

/*
 * Provider-discovery request JSON uses the common versioned envelope:
 * {"request_schema_version":1,"payload":{...}}.
 *
 * inspect_provider_curl never persists raw_curl. Safe metadata is returned in
 * out_metadata; a detected credential is returned separately in
 * out_credential and must be copied immediately to the native OS credential
 * store. Both buffers are released with lorepia_buffer_free. Errors,
 * discovery snapshots, outbox events, and SQLite never contain that secret.
 *
 * request_json uses the versioned envelope and contains connection_options.
 * Its network_mode is one of public, local_loopback, or
 * approved_local_network. approved_local_network requires the exact
 * local_network_approval origin and finite resolved-address grant. No legacy
 * local-network boolean is accepted.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_inspect_provider_curl_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *raw_curl,
    size_t raw_curl_len,
    lorepia_buffer_t *out_metadata,
    lorepia_buffer_t *out_credential
);

/*
 * Begin payload:
 * {
 *   "input": {
 *     "connection_id": string,
 *     "display_name": string,
 *     "site_url": string|null,
 *     "docs_url": string|null,
 *     "credential_slot_ready": bool,
 *     "preferred_assistant_model_route_id": string|null,
 *     "connection_options": {
 *       "values": [{"key":string,"value":typed-value}],
 *       "api_base_path": string|null,
 *       "timeout_seconds": integer,
 *       "network_mode": "public"|"local_loopback"|"approved_local_network",
 *       "local_network_approval":
 *         null|{"origin":string,"addresses":[string]}
 *     },
 *     "supplied_evidence_ids": [string]
 *   },
 *   "source":
 *     {"kind":"known_provider","template_id":string} |
 *     {"kind":"site"} |
 *     {"kind":"curl"}
 * }
 *
 * When credential_slot_ready is true, Core derives credential_ref exactly
 * from connection_id. Native clients therefore know the final OS
 * credential-store key before begin, and no arbitrary credential reference is
 * accepted at the ABI boundary.
 *
 * raw_curl must be present only for the curl source and is one-shot.
 *
 * Every returned discovery snapshot schema version 3 exposes
 * pending_connection_id, pending_display_name, connection_options,
 * credential_slot_expected, and credential_slot_id. connection_options is the
 * exact secret-free values, API base path, timeout, network mode, and optional
 * local-network approval persisted at begin; restarted clients must reuse it
 * for supplemental inspection. When a slot is expected, credential_slot_id is
 * non-null and exactly equals pending_connection_id.
 *
 * assistant_resume_boundary is null unless a durable setup-assistant flow has
 * an exact native restart action. Its checkpoint is null or one of ready,
 * awaiting_assistant, awaiting_tool_result, awaiting_more_evidence,
 * awaiting_retry_consent, and draft_ready. Its action is one of
 * approve_consent, run_assistant, wait_for_assistant_outcome,
 * resume_core_host_action, supply_more_evidence, approve_retry, review_draft,
 * restart_interrupted, and resolve_unknown_outcome. questions and the optional
 * draft_review are typed nested objects. Native code must use this projection
 * directly instead of inferring a resume action from state or draft JSON.
 *
 * Discovery state, operation, action-required, progress, warning, step,
 * evidence, approval, review-change, and compensation control fields are
 * emitted from closed Rust enums as snake_case JSON strings. Unknown variants
 * cannot be injected through this ABI.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_begin_provider_discovery_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *raw_curl,
    size_t raw_curl_len,
    uint8_t raw_curl_present,
    lorepia_buffer_t *out_buffer
);

/*
 * Prepares a canonical typed action envelope. Native code should submit its
 * action_id, expected_revision, typed public action, then echo the returned
 * request_sha256 unchanged to continue_provider_discovery_json.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_prepare_provider_discovery_action_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_provider_discovery_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_discoveries_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_discovery_candidates_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_discovery_evidence_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_discovery_approvals_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_provider_discovery_review_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_provider_discovery_approval_proposal_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_get_provider_discovery_review_proposal_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);

/*
 * Continue payload contains session_id, action_id, expected_revision,
 * request_sha256, and one closed typed public action. credential remains a
 * request-scoped scalar and is never a JSON member.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_continue_provider_discovery_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
/*
 * Supplies one fresh evidence source while the session is awaiting evidence.
 * Payload contains session_id, expected_revision, and either
 * {"kind":"document_url","url":string} or {"kind":"curl"}.
 * raw_curl must be present only for the curl source and is consumed one time;
 * no raw command, header value, cookie, query value, or extracted credential
 * is persisted.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_supply_provider_discovery_evidence_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *raw_curl,
    size_t raw_curl_len,
    uint8_t raw_curl_present,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_cancel_provider_discovery_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_commit_provider_discovery_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_recover_provider_discoveries_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_poll_provider_discovery_events_json(
    const lorepia_core_t *core,
    uint32_t max_events,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_ack_provider_discovery_event_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);

/*
 * Compensation steps are immutable typed targets listed in descending
 * execution order. Native code may execute only remove_credential_slot; Core
 * owns remove_connection_graph and restore_previous_selection. Each lifecycle
 * method verifies the step kind and current durable status. Step lifecycle
 * payloads contain {"session_id":string,"step_id":string}; failure additionally
 * contains failure_code, failure_message_key, and recoverable.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_provider_discovery_compensation_steps_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_start_provider_discovery_credential_compensation_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_complete_provider_discovery_credential_compensation_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_fail_provider_discovery_credential_compensation_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_mark_provider_discovery_credential_compensation_unknown_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);

/*
 * Setup-assistant requests use the same versioned envelope and closed Rust
 * schemas. Core performs the model call; the assistant credential is a
 * separate request-scoped scalar. The high-level runner executes every closed
 * tool action inside Core and returns only a typed request_more_evidence or
 * review_draft boundary. questions and draft_review are nested typed objects,
 * never JSON-encoded strings. Raw model output, public tool-result submission,
 * and arbitrary URL or HTTP execution are never exposed.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_run_provider_discovery_assistant_turn_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *credential,
    size_t credential_len,
    uint8_t credential_present,
    lorepia_buffer_t *out_buffer
);
/*
 * Resumes the typed resume_core_host_action boundary. Core restores and
 * executes only its durably pending allowlisted tool, then submits the typed
 * result internally. No raw tool call or result is accepted or returned.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_resume_provider_discovery_assistant_core_host_action_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_approve_provider_discovery_assistant_retry_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_request_provider_discovery_assistant_revision_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_accept_provider_discovery_assistant_draft_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_record_provider_discovery_assistant_failure_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);

/*
 * Every catalog diff returned by status-adjacent operations is a typed
 * six-bucket object:
 *   added_provider_templates, changed_provider_templates,
 *   removed_provider_templates, added_models, changed_models, removed_models.
 * Entries expose IDs, previous/next versions and SHA-256 values, plus closed
 * changed_sections strings. Native product code never parses a diff_json
 * string.
 *
 * Prepare-import and prepare-rollback responses also contain plan_json. Treat
 * that value as an opaque Core token and echo it unchanged in the activation
 * request payload as {"plan_json":string}. Native code renders the sibling
 * typed review/diff fields and does not parse the opaque plan token.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_provider_catalog_status_json(
    const lorepia_core_t *core,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_provider_catalog_history_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_prepare_signed_provider_catalog_import_json(
    const lorepia_core_t *core,
    const uint8_t *envelope_json,
    size_t envelope_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_activate_signed_provider_catalog_import_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    const uint8_t *envelope_json,
    size_t envelope_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_diff_provider_catalog_revisions_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_prepare_provider_catalog_rollback_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_activate_provider_catalog_rollback_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_list_generation_presets_json(
    const lorepia_core_t *core,
    const uint8_t *model_route_id,
    size_t model_route_id_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_upsert_generation_preset_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_validate_generation_preset_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_validate_generation_preset_candidate_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_render_reasoning_control_candidate_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_render_prompt_cache_control_candidate_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
/*
 * Request previews are returned as a closed typed object containing method,
 * origin, path, safe header/query names, body_truncated, and optional
 * body_shape. body_shape is a recursive tagged object with kind null, boolean,
 * number, string, array, object, redacted, or truncated. Array nodes contain
 * typed items; object nodes contain typed {name,shape} fields. No nested JSON
 * string or provider scalar value is exposed.
 */
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_preview_provider_request_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_preview_provider_request_candidate_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_delete_generation_preset_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len
);
LOREPIA_API int32_t LOREPIA_CALL lorepia_core_select_generation_target_json(
    const lorepia_core_t *core,
    const uint8_t *request_json,
    size_t request_json_len,
    lorepia_buffer_t *out_buffer
);

/* Legacy ABI v3 provider-profile functions retained for compatibility. */
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

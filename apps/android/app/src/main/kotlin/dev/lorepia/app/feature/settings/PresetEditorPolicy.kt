package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.ParameterCondition
import dev.lorepia.app.bridge.ParameterConditionOperator
import dev.lorepia.app.bridge.ParameterConflictKind
import dev.lorepia.app.bridge.ParameterDefaultMode
import dev.lorepia.app.bridge.ParameterLiteral
import dev.lorepia.app.bridge.ParameterSpec
import dev.lorepia.app.bridge.ParameterType
import dev.lorepia.app.bridge.UiParameterLevel

internal fun validatePresetEditor(editor: PresetEditor): List<String> = buildList {
    if (editor.displayName.isBlank()) {
        add("Preset 이름을 입력해 주세요.")
    }
    val specsById = editor.parameterSpecs.associateBy(ParameterSpec::id)
    editor.explicitValues.keys
        .filterNot(specsById::containsKey)
        .forEach { add("알 수 없는 파라미터 '$it'가 있습니다.") }

    editor.parameterSpecs.forEach { spec ->
        val explicit = editor.explicitValues[spec.id]
        if (spec.defaultMode == ParameterDefaultMode.ExplicitRequired &&
            isParameterVisible(spec, editor.explicitValues) &&
            explicit == null
        ) {
            add("${spec.labelKey}: 값을 직접 선택해야 합니다.")
        }
        if (explicit != null) {
            if (!isParameterVisible(spec, editor.explicitValues)) {
                add("${spec.labelKey}: 현재 조건에서는 사용할 수 없는 값입니다.")
            }
            validateLiteral(spec, explicit)?.let(::add)
            spec.conflicts.forEach { conflict ->
                val otherIsExplicit = editor.explicitValues.containsKey(conflict.parameterId)
                when (conflict.kind) {
                    ParameterConflictKind.MutuallyExclusive -> {
                        if (otherIsExplicit) add(conflict.messageKey)
                    }

                    ParameterConflictKind.Requires -> {
                        if (!otherIsExplicit) add(conflict.messageKey)
                    }
                }
            }
        }
    }

    if (editor.reasoningBudgetTokens.isNotBlank() &&
        editor.reasoningBudgetTokens.toUIntOrNull()?.takeIf { it > 0u } == null
    ) {
        add("추론 토큰 예산은 1 이상의 정수여야 합니다.")
    }
    if (editor.reasoningMode in setOf("provider_default", "disabled") &&
        (editor.reasoningEffort != null || editor.reasoningBudgetTokens.isNotBlank())
    ) {
        add("추론을 끈 상태에서는 effort 또는 토큰 예산을 지정할 수 없습니다.")
    }
    if (editor.reasoningMode !in VALID_REASONING_MODES) {
        add("지원하지 않는 추론 모드입니다.")
    }
    if (editor.reasoningEffort != null &&
        editor.reasoningEffort !in VALID_REASONING_EFFORTS
    ) {
        add("지원하지 않는 추론 effort입니다.")
    }
    if (editor.reasoningSummary !in VALID_REASONING_SUMMARIES) {
        add("지원하지 않는 추론 요약 모드입니다.")
    }
    if (editor.reasoningMode == "disabled" &&
        editor.reasoningSummary !in setOf("provider_default", "disabled")
    ) {
        add("추론을 끈 상태에서는 추론 요약을 활성화할 수 없습니다.")
    }
    if (editor.promptCacheMode !in VALID_PROMPT_CACHE_MODES) {
        add("지원하지 않는 prompt cache 모드입니다.")
    }
    if (editor.promptCacheTtl !in VALID_PROMPT_CACHE_TTLS) {
        add("지원하지 않는 prompt cache TTL입니다.")
    }
    if (editor.promptCacheTtl == "custom_seconds") {
        val ttl = editor.promptCacheCustomTtlSeconds.toUIntOrNull()
        if (ttl == null || ttl == 0u) {
            add("사용자 지정 캐시 TTL은 1초 이상의 정수여야 합니다.")
        }
    } else if (editor.promptCacheCustomTtlSeconds.isNotBlank()) {
        add("사용자 지정 TTL을 선택했을 때만 초 값을 입력할 수 있습니다.")
    }
    if (editor.promptCacheMode == "explicit_context" &&
        editor.promptCacheContextReference.isBlank()
    ) {
        add("명시적 context cache에는 resource 이름이 필요합니다.")
    } else if (editor.promptCacheMode != "explicit_context" &&
        editor.promptCacheContextReference.isNotBlank()
    ) {
        add("Cached context resource는 명시적 context 모드에서만 사용할 수 있습니다.")
    }
    if (editor.promptCacheMode in setOf(
            "provider_default",
            "disabled_if_supported",
            "explicit_context",
        ) &&
        editor.promptCacheTtl != "provider_default"
    ) {
        add("선택한 prompt cache 모드에서는 TTL을 별도로 지정할 수 없습니다.")
    }
}

internal fun validatePresetControls(
    editor: PresetEditor,
    controls: PresetControls,
    credentialBearingConnection: Boolean,
): List<String> = buildList {
    val reasoning = controls.reasoning
    val cache = controls.promptCache
    addAll(reasoning.issues.map { it.message })
    addAll(cache.issues.map { it.message })
    if (reasoning.state == "invalid") {
        add("선택한 추론 설정을 이 route에서 사용할 수 없습니다.")
    }
    if (cache.state == "invalid") {
        add("선택한 prompt cache 설정을 이 route에서 사용할 수 없습니다.")
    }
    if (reasoning.effortField == "required" && editor.reasoningEffort == null) {
        add("추론 effort를 직접 선택해 주세요.")
    }
    if (
        editor.reasoningEffort != null &&
        editor.reasoningEffort !in reasoning.allowedEfforts
    ) {
        add("이 route에서 사용할 수 없는 추론 effort입니다.")
    }
    if (reasoning.effortField == "hidden" && editor.reasoningEffort != null) {
        add("숨겨진 추론 effort는 요청에서 생략해야 합니다.")
    }
    if (
        reasoning.effort != null &&
        reasoning.effort !in reasoning.allowedEfforts
    ) {
        add("Core가 허용 목록 밖의 추론 effort를 반환했습니다.")
    }
    if (reasoning.effortField == "hidden" && reasoning.effort != null) {
        add("Core가 숨겨진 추론 effort 값을 반환했습니다.")
    }
    if (reasoning.budgetField == "required") {
        val budget = editor.reasoningBudgetTokens.toUIntOrNull()
        if (budget == null ||
            budget == 0u ||
            reasoning.minimumBudgetTokens?.let { budget < it } == true ||
            reasoning.maximumBudgetTokens?.let { budget > it } == true
        ) {
            add("허용 범위 안의 추론 토큰 예산을 직접 입력해 주세요.")
        }
    }
    if (reasoning.summaryField == "required" &&
        editor.reasoningSummary == "provider_default"
    ) {
        add("추론 요약 모드를 직접 선택해 주세요.")
    }
    if (
        editor.preserveOpaqueReasoningState &&
        (!reasoning.preserveOpaqueState || credentialBearingConnection)
    ) {
        add("이 연결에서는 opaque reasoning state 유지를 사용할 수 없습니다.")
    }
    if (cache.ttlField == "required" &&
        editor.promptCacheTtl == "provider_default"
    ) {
        add("Cache TTL을 직접 선택해 주세요.")
    }
    if (editor.promptCacheTtl == "custom_seconds" && !cache.supportsCustomTtl) {
        add("이 route는 사용자 지정 cache TTL을 지원하지 않습니다.")
    }
    if (editor.promptCacheTtl != "custom_seconds" &&
        editor.promptCacheTtl !in cache.allowedTtls
    ) {
        add("이 route에서 사용할 수 없는 cache TTL입니다.")
    }
    if (cache.contextReferenceField == "required" &&
        editor.promptCacheContextReference.isBlank()
    ) {
        add("Cached context resource를 입력해 주세요.")
    }
}.distinct()

/**
 * Keeps the editable parameter graph representable as conditional controls
 * appear and disappear. Hidden values must be omitted from the provider
 * request, while a visible explicit-required value must always have a control
 * the user can operate.
 */
internal fun normalizePresetEditor(editor: PresetEditor): PresetEditor {
    var values = editor.explicitValues
    repeat((editor.parameterSpecs.size * 2).coerceAtLeast(1)) {
        val visibleIds = editor.parameterSpecs
            .filter { isParameterVisible(it, values) }
            .mapTo(mutableSetOf(), ParameterSpec::id)
        val withoutHidden = values.filterKeys(visibleIds::contains)
        if (withoutHidden == values) {
            val missingRequiredLevel = editor.parameterSpecs
                .asSequence()
                .filter { it.id in visibleIds }
                .filter { it.defaultMode == ParameterDefaultMode.ExplicitRequired }
                .filterNot { values.containsKey(it.id) }
                .map(ParameterSpec::level)
                .filter { it != UiParameterLevel.HiddenInternal }
                .maxByOrNull(UiParameterLevel::ordinal)
            return editor.copy(
                explicitValues = values,
                visibleLevel = maxOf(
                    editor.visibleLevel,
                    missingRequiredLevel ?: editor.visibleLevel,
                ),
            )
        }
        values = withoutHidden
    }
    return editor.copy(explicitValues = values)
}

internal fun isParameterVisible(
    spec: ParameterSpec,
    explicitValues: Map<String, ParameterLiteral>,
): Boolean {
    val condition = spec.visibility ?: return true
    val actual = explicitValues[condition.parameterId] ?: return false
    val equal = literalsEqual(actual, condition.value)
    return when (condition.operator) {
        ParameterConditionOperator.Equals -> equal
        ParameterConditionOperator.NotEquals -> !equal
    }
}

internal fun defaultEditorLiteral(spec: ParameterSpec): ParameterLiteral = when (spec.valueType) {
    ParameterType.Boolean -> ParameterLiteral.Boolean(false)
    ParameterType.Integer -> ParameterLiteral.Integer(spec.minimum?.toLong() ?: 0L)
    ParameterType.Number -> ParameterLiteral.Number(spec.minimum ?: 0.0)
    ParameterType.String -> ParameterLiteral.StringValue("")
    ParameterType.Enum -> spec.allowedValues.firstOrNull()?.value
        ?: ParameterLiteral.EnumValue("")
    ParameterType.StringList -> ParameterLiteral.StringList(emptyList())
    ParameterType.JsonSchema -> ParameterLiteral.JsonSchema("{}")
    ParameterType.StopSequenceList -> ParameterLiteral.StopSequenceList(emptyList())
    ParameterType.ToolPolicy -> ParameterLiteral.ToolPolicyValue(
        dev.lorepia.app.bridge.ToolPolicy.Auto,
    )
}

private fun validateLiteral(spec: ParameterSpec, literal: ParameterLiteral): String? {
    val typeMatches = when (spec.valueType) {
        ParameterType.Boolean -> literal is ParameterLiteral.Boolean
        ParameterType.Integer -> literal is ParameterLiteral.Integer
        ParameterType.Number -> literal is ParameterLiteral.Number
        ParameterType.String -> literal is ParameterLiteral.StringValue
        ParameterType.Enum -> literal is ParameterLiteral.EnumValue
        ParameterType.StringList -> literal is ParameterLiteral.StringList
        ParameterType.JsonSchema -> literal is ParameterLiteral.JsonSchema
        ParameterType.StopSequenceList -> literal is ParameterLiteral.StopSequenceList
        ParameterType.ToolPolicy -> literal is ParameterLiteral.ToolPolicyValue
    }
    if (!typeMatches) return "${spec.labelKey}: 값 형식이 맞지 않습니다."

    val numeric = when (literal) {
        is ParameterLiteral.Integer -> literal.value.toDouble()
        is ParameterLiteral.Number -> literal.value
        else -> null
    }
    if (numeric != null && !numeric.isFinite()) {
        return "${spec.labelKey}: 유한한 숫자여야 합니다."
    }
    if (numeric != null && spec.minimum != null && numeric < spec.minimum) {
        return "${spec.labelKey}: 최솟값은 ${spec.minimum}입니다."
    }
    if (numeric != null && spec.maximum != null && numeric > spec.maximum) {
        return "${spec.labelKey}: 최댓값은 ${spec.maximum}입니다."
    }
    if (numeric != null && spec.step != null && spec.step > 0.0) {
        val units = (numeric - (spec.minimum ?: 0.0)) / spec.step
        val distance = kotlin.math.abs(units - kotlin.math.round(units))
        val tolerance = 1e-9 * kotlin.math.max(1.0, kotlin.math.abs(units))
        if (distance > tolerance) {
            return "${spec.labelKey}: ${spec.step} 단위 값이어야 합니다."
        }
    }
    if (literal is ParameterLiteral.EnumValue &&
        spec.allowedValues.isNotEmpty() &&
        spec.allowedValues.none { literalsEqual(it.value, literal) }
    ) {
        return "${spec.labelKey}: 허용되지 않은 값입니다."
    }
    if (spec.defaultMode == ParameterDefaultMode.ExplicitRequired) {
        val isEmpty = when (literal) {
            is ParameterLiteral.StringValue -> literal.value.isBlank()
            is ParameterLiteral.StringList -> literal.values.isEmpty()
            is ParameterLiteral.JsonSchema -> literal.value.isBlank()
            is ParameterLiteral.StopSequenceList -> literal.values.isEmpty()
            is ParameterLiteral.EnumValue -> literal.value.isBlank()
            else -> false
        }
        if (isEmpty) return "${spec.labelKey}: 빈 값은 직접 선택한 값으로 사용할 수 없습니다."
    }
    val textSize = when (literal) {
        is ParameterLiteral.JsonSchema -> literal.value.length
        is ParameterLiteral.StringValue -> literal.value.length
        else -> 0
    }
    if (textSize > MAX_EDITOR_TEXT_CHARACTERS) {
        return "${spec.labelKey}: 값이 너무 깁니다."
    }
    return null
}

private fun literalsEqual(left: ParameterLiteral, right: ParameterLiteral): Boolean =
    left == right

private const val MAX_EDITOR_TEXT_CHARACTERS = 65_536
private val VALID_REASONING_MODES =
    setOf("provider_default", "disabled", "automatic", "enabled")
private val VALID_REASONING_EFFORTS =
    setOf("minimal", "low", "medium", "high", "extra_high", "maximum")
private val VALID_REASONING_SUMMARIES =
    setOf("provider_default", "disabled", "automatic", "concise", "detailed")
private val VALID_PROMPT_CACHE_MODES = setOf(
    "provider_default",
    "automatic",
    "explicit_breakpoints",
    "explicit_context",
    "disabled_if_supported",
)
private val VALID_PROMPT_CACHE_TTLS =
    setOf("provider_default", "short", "long", "custom_seconds")

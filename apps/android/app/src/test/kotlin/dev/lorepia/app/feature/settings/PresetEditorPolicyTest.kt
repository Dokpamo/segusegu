package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.ParameterCondition
import dev.lorepia.app.bridge.ParameterConditionOperator
import dev.lorepia.app.bridge.ParameterConflict
import dev.lorepia.app.bridge.ParameterConflictKind
import dev.lorepia.app.bridge.ParameterDefaultMode
import dev.lorepia.app.bridge.ParameterLiteral
import dev.lorepia.app.bridge.ParameterSpec
import dev.lorepia.app.bridge.ParameterType
import dev.lorepia.app.bridge.ProviderParameterMapping
import dev.lorepia.app.bridge.ProviderParameterTarget
import dev.lorepia.app.bridge.UiParameterLevel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PresetEditorPolicyTest {
    @Test
    fun `provider-default value remains valid and omitted`() {
        val editor = editor(parameterSpecs = listOf(spec("temperature", ParameterType.Number)))

        assertTrue(editor.explicitValues.isEmpty())
        assertTrue(validatePresetEditor(editor).isEmpty())
    }

    @Test
    fun `required explicit value and numeric range are validated`() {
        val required = spec(
            id = "max_output_tokens",
            type = ParameterType.Integer,
            defaultMode = ParameterDefaultMode.ExplicitRequired,
            minimum = 1.0,
            maximum = 4096.0,
        )
        val missing = editor(parameterSpecs = listOf(required))
        assertFalse(validatePresetEditor(missing).isEmpty())

        val invalid = missing.copy(
            explicitValues = mapOf(
                required.id to ParameterLiteral.Integer(10_000),
            ),
        )
        assertTrue(
            validatePresetEditor(invalid).any { it.contains("최댓값") },
        )
    }

    @Test
    fun `visibility and mutually exclusive conflicts fail closed`() {
        val reasoningEnabled = spec("reasoning_enabled", ParameterType.Boolean)
        val budget = spec(
            id = "reasoning_budget",
            type = ParameterType.Integer,
            visibility = ParameterCondition(
                parameterId = reasoningEnabled.id,
                operator = ParameterConditionOperator.Equals,
                value = ParameterLiteral.Boolean(true),
            ),
            conflicts = listOf(
                ParameterConflict(
                    parameterId = "reasoning_effort",
                    kind = ParameterConflictKind.MutuallyExclusive,
                    messageKey = "reasoning budget and effort conflict",
                ),
            ),
        )
        val effort = spec("reasoning_effort", ParameterType.String)
        val hidden = editor(
            parameterSpecs = listOf(reasoningEnabled, budget, effort),
            explicitValues = mapOf(budget.id to ParameterLiteral.Integer(128)),
        )
        assertFalse(isParameterVisible(budget, hidden.explicitValues))
        assertTrue(
            validatePresetEditor(hidden).any { it.contains("사용할 수 없는") },
        )

        val conflict = hidden.copy(
            explicitValues = hidden.explicitValues + mapOf(
                reasoningEnabled.id to ParameterLiteral.Boolean(true),
                effort.id to ParameterLiteral.StringValue("high"),
            ),
        )
        assertTrue(
            validatePresetEditor(conflict).any { it.contains("conflict") },
        )
    }

    @Test
    fun `normalization removes hidden values and leaves required values for user choice`() {
        val enabled = spec("enabled", ParameterType.Boolean)
        val requiredBudget = spec(
            id = "budget",
            type = ParameterType.Integer,
            defaultMode = ParameterDefaultMode.ExplicitRequired,
            minimum = 1.0,
            visibility = ParameterCondition(
                parameterId = enabled.id,
                operator = ParameterConditionOperator.Equals,
                value = ParameterLiteral.Boolean(true),
            ),
        )
        val hidden = editor(
            parameterSpecs = listOf(enabled, requiredBudget),
            explicitValues = mapOf(requiredBudget.id to ParameterLiteral.Integer(64)),
        )

        val withoutHidden = normalizePresetEditor(hidden)
        assertFalse(withoutHidden.explicitValues.containsKey(requiredBudget.id))

        val visible = normalizePresetEditor(
            hidden.copy(
                explicitValues = mapOf(enabled.id to ParameterLiteral.Boolean(true)),
            ),
        )
        assertFalse(visible.explicitValues.containsKey(requiredBudget.id))
        assertTrue(
            validatePresetEditor(visible).any { it.contains("직접 선택") },
        )
    }
}

private fun editor(
    parameterSpecs: List<ParameterSpec>,
    explicitValues: Map<String, ParameterLiteral> = emptyMap(),
): PresetEditor = PresetEditor(
    id = "preset",
    modelRouteId = "route",
    displayName = "테스트",
    parameterSpecs = parameterSpecs,
    explicitValues = explicitValues,
)

private fun spec(
    id: String,
    type: ParameterType,
    defaultMode: ParameterDefaultMode = ParameterDefaultMode.ProviderDefault,
    minimum: Double? = null,
    maximum: Double? = null,
    visibility: ParameterCondition? = null,
    conflicts: List<ParameterConflict> = emptyList(),
): ParameterSpec = ParameterSpec(
    id = id,
    labelKey = id,
    descriptionKey = null,
    valueType = type,
    allowedValues = emptyList(),
    minimum = minimum,
    maximum = maximum,
    step = null,
    defaultMode = defaultMode,
    visibility = visibility,
    conflicts = conflicts,
    providerMapping = ProviderParameterMapping(
        target = ProviderParameterTarget.RequestBody,
        fieldName = id,
    ),
    level = UiParameterLevel.Basic,
)

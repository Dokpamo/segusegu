using Lorepia.App.ViewModels;
using Lorepia.Native;
using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class ProviderPresentationModelsTests
{
    [Fact]
    public void ProviderDefaultIsSerializedAsAnExplicitState()
    {
        var editor = new ProviderParameterEditor(new ProviderParameterSpec
        {
            Id = "temperature",
            LabelKey = "Temperature",
            ValueType = "number",
            Minimum = 0,
            Maximum = 2,
            DefaultMode = "provider_default",
        });

        Assert.True(editor.TryBuild(out var value, out var error));
        Assert.Null(error);
        Assert.Equal(
            "inherit_provider_default",
            value?.State.State);
        Assert.Null(value?.State.Value);
    }

    [Fact]
    public void NumericEditorRejectsOutOfRangeValueLocally()
    {
        var editor = new ProviderParameterEditor(new ProviderParameterSpec
        {
            Id = "temperature",
            LabelKey = "Temperature",
            ValueType = "number",
            Minimum = 0,
            Maximum = 2,
            DefaultMode = "provider_default",
        })
        {
            UseProviderDefault = false,
            Input = "9.5",
        };

        Assert.False(editor.TryBuild(out var value, out var error));
        Assert.Null(value);
        Assert.Contains(
            "outside",
            error,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void NumericEditorRejectsValueOutsideProviderStep()
    {
        var editor = new ProviderParameterEditor(new ProviderParameterSpec
        {
            Id = "temperature",
            LabelKey = "Temperature",
            ValueType = "number",
            Minimum = 0,
            Maximum = 2,
            Step = 0.1,
            DefaultMode = "provider_default",
        })
        {
            UseProviderDefault = false,
            Input = "0.75",
        };

        Assert.False(editor.TryBuild(out var value, out var error));
        Assert.Null(value);
        Assert.Contains(
            "step",
            error,
            StringComparison.OrdinalIgnoreCase);
        Assert.Contains(
            "0.1",
            editor.Constraint,
            StringComparison.Ordinal);
    }

    [Fact]
    public void JsonSchemaEditorValidatesButKeepsSchemaAsAStringLiteral()
    {
        var editor = new ProviderParameterEditor(new ProviderParameterSpec
        {
            Id = "response_schema",
            LabelKey = "Response schema",
            ValueType = "json_schema",
            DefaultMode = "provider_default",
        })
        {
            UseProviderDefault = false,
            Input = """{"type":"object"}""",
        };

        Assert.True(editor.TryBuild(out var value, out var error));
        Assert.Null(error);
        Assert.Equal(
            "json_schema",
            value?.State.Value?.Type);
        Assert.Equal(
            """{"type":"object"}""",
            value?.State.Value?.Value.GetString());
    }

    [Fact]
    public void StopSequenceListRoundTripsWithoutMergingEntries()
    {
        var editor = new ProviderParameterEditor(new ProviderParameterSpec
        {
            Id = "stop",
            LabelKey = "Stop sequences",
            ValueType = "stop_sequence_list",
            DefaultMode = "provider_default",
        });
        editor.Load(new ProviderParameterValue
        {
            ParameterId = "stop",
            State = new ProviderParameterValueState
            {
                State = "explicit",
                Value = new ProviderParameterLiteral
                {
                    Type = "stop_sequence_list",
                    Value = JsonSerializer.SerializeToElement(
                        new[] { "first", "second" }),
                },
            },
        });

        Assert.Equal(
            $"first{Environment.NewLine}second",
            editor.Input);
        Assert.True(editor.TryBuild(out var value, out var error));
        Assert.Null(error);
        Assert.Equal(
            new[] { "first", "second" },
            value?.State.Value?.Value
                .EnumerateArray()
                .Select(item => item.GetString())
                .ToArray());
    }

    [Fact]
    public void CredentialConnectionFieldNeverBecomesNonSecretConfig()
    {
        var editor = new ConnectionFieldEditor(new ConnectionFieldSpec
        {
            Key = "api_key",
            LabelKey = "API key",
            ValueType = ConnectionFieldType.Credential,
            Required = true,
        })
        {
            Value = "must-not-enter-config",
        };

        Assert.False(editor.TryBuild(out var entry, out var error));
        Assert.Null(entry);
        Assert.Contains(
            "PasswordVault",
            error,
            StringComparison.Ordinal);
    }

    [Fact]
    public void CapabilityPresentationShowsProvenanceFreshnessAndConflict()
    {
        var observedAt = DateTimeOffset.Parse(
            "2026-07-30T10:00:00Z",
            System.Globalization.CultureInfo.InvariantCulture);
        var selected = new CapabilityObservation
        {
            Id = "observation-a",
            ModelRouteId = "route-a",
            Key = CapabilityKey.StructuredOutput,
            Value = CapabilityValue.Boolean(true),
            Status = CapabilitySupportStatus.Verified,
            Source = CapabilityObservationSource.CapabilityProbe,
            Confidence = CapabilityConfidence.High,
            ObservedAt = observedAt,
            ExpiresAt = observedAt.AddDays(7),
            EvidenceRef = "probe-a",
        };

        var display = CapabilityDisplayItem.From(
            new EffectiveCapability
            {
                Selected = selected,
                Alternatives =
                [
                    selected with
                    {
                        Id = "observation-b",
                        Source =
                            CapabilityObservationSource.OfficialDocumentation,
                    },
                ],
                EvaluatedAt = observedAt.AddDays(8),
                SelectedIsStale = true,
                HasConflict = true,
            });

        Assert.Equal("Structured Output", display.Key);
        Assert.Equal("Supported", display.Value);
        Assert.Equal("Capability Probe", display.Source);
        Assert.StartsWith("Stale", display.Freshness);
        Assert.Contains("1", display.Conflict);
        Assert.Equal("probe-a", display.Evidence);
    }
}

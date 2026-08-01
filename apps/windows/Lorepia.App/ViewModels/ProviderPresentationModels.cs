using Lorepia.Native;
using System.Globalization;
using System.Text.Json;

namespace Lorepia.App.ViewModels;

public enum ProviderSetupMode
{
    KnownProvider,
    WebsiteDiscovery,
    CurlExample,
    LocalServer,
}

public sealed record ProviderSetupModeOption(
    ProviderSetupMode Mode,
    string Label,
    string Description);

public sealed record ProviderNetworkModeOption(
    ProviderNetworkMode Mode,
    string Label,
    string Description);

public sealed record ProviderProgressItem(
    string Marker,
    string Label,
    string Detail);

public sealed record ProviderDiscoveryCandidateItem(
    ProviderDiscoveryCandidate Candidate)
{
    public string Id => Candidate.Id;

    public string Label => Candidate.Summary.Kind switch
    {
        "provider_template" =>
            Candidate.Summary.TemplateId
            ?? "Provider template",
        "api_origin" =>
            Candidate.Summary.Origin
            ?? "API origin",
        "official_document" =>
            "Official document",
        "model_route" =>
            Candidate.Summary.ModelId
            ?? "Model route",
        "manifest_draft" =>
            "Manifest draft",
        _ => Candidate.Summary.Kind,
    };

    public string Detail =>
        $"{Candidate.Summary.Kind} · revision {Candidate.ProposedRevision} · {Candidate.EvidenceIds.Count} evidence item(s)";
}

public sealed record ProviderDiscoveryResolutionOption(
    string Resolution,
    string Label,
    string Description);

public sealed record AssistantModelRouteOption(
    string ConnectionId,
    string ConnectionDisplayName,
    ModelRoute Route,
    GenerationPreset Preset)
{
    public string Id => Route.Id;

    public string Label =>
        $"App default · {ConnectionDisplayName} · {Route.DisplayName ?? Route.ModelId}";

    public string Detail =>
        $"route {Route.Id} · preset {Preset.DisplayName} ({Preset.Id}) · model {Route.ModelId} · connection {ConnectionId}";
}

public sealed record ModelSyncReviewItem(
    string Marker,
    string Label,
    string Detail);

public sealed record ProviderCatalogRevisionItem(
    ulong Revision,
    string Label,
    string Detail,
    bool IsActive);

public sealed record CapabilityDisplayItem(
    string Key,
    string Value,
    string Status,
    string Source,
    string Freshness,
    string Conflict,
    string Evidence)
{
    internal static CapabilityDisplayItem From(
        EffectiveCapability capability)
    {
        ArgumentNullException.ThrowIfNull(capability);
        var observation = capability.Selected;
        return new CapabilityDisplayItem(
            Humanize(observation.Key.ToString()),
            FormatCapabilityValue(observation.Value),
            Humanize(observation.Status.ToString()),
            Humanize(observation.Source.ToString()),
            capability.SelectedIsStale
                ? $"Stale · checked {observation.ObservedAt.LocalDateTime:g}"
                : $"Current · checked {observation.ObservedAt.LocalDateTime:g}",
            capability.HasConflict
                ? $"{capability.Alternatives.Count} conflicting source(s)"
                : "No conflict",
            observation.EvidenceRef ?? "No evidence reference");
    }

    private static string FormatCapabilityValue(CapabilityValue value)
    {
        return value.Type switch
        {
            "boolean" when value.Value.ValueKind
                is JsonValueKind.True or JsonValueKind.False
                => value.Value.GetBoolean() ? "Supported" : "Not supported",
            "integer" when value.Value.TryGetUInt64(out var number)
                => number.ToString("N0", CultureInfo.CurrentCulture),
            "enum_values" when value.Value.ValueKind == JsonValueKind.Array
                => string.Join(
                    ", ",
                    value.Value.EnumerateArray().Select(item =>
                        item.GetString() ?? string.Empty)),
            _ => "Structured value",
        };
    }

    internal static string Humanize(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        var characters = new List<char>(value.Length + 8)
        {
            char.ToUpperInvariant(value[0]),
        };
        foreach (var character in value.AsSpan(1))
        {
            if (char.IsUpper(character))
            {
                characters.Add(' ');
            }

            characters.Add(character);
        }

        return new string([.. characters]);
    }
}

public sealed class ConnectionFieldEditor : ObservableObject
{
    private string value = string.Empty;

    internal ConnectionFieldEditor(ConnectionFieldSpec spec)
    {
        Spec = spec ?? throw new ArgumentNullException(nameof(spec));
    }

    internal ConnectionFieldSpec Spec { get; }

    public string Key => Spec.Key;

    public string Label => Spec.LabelKey;

    public string Description => Spec.DescriptionKey ?? string.Empty;

    public string TypeLabel =>
        CapabilityDisplayItem.Humanize(Spec.ValueType.ToString());

    public bool IsRequired => Spec.Required;

    public string Value
    {
        get => value;
        set => SetProperty(ref this.value, value);
    }

    internal bool TryBuild(
        out ConnectionConfigEntry? entry,
        out string? error)
    {
        var normalized = Value.Trim();
        if (normalized.Length == 0)
        {
            entry = null;
            error = IsRequired ? $"{Label} is required." : null;
            return !IsRequired;
        }

        ConnectionConfigValue configValue;
        switch (Spec.ValueType)
        {
            case ConnectionFieldType.Text:
                configValue = ConnectionConfigValue.Text(normalized);
                break;
            case ConnectionFieldType.Integer:
                if (!long.TryParse(
                        normalized,
                        NumberStyles.Integer,
                        CultureInfo.InvariantCulture,
                        out var integer))
                {
                    entry = null;
                    error = $"{Label} must be a whole number.";
                    return false;
                }

                configValue = ConnectionConfigValue.Integer(integer);
                break;
            case ConnectionFieldType.Boolean:
                if (!bool.TryParse(normalized, out var boolean))
                {
                    entry = null;
                    error = $"{Label} must be true or false.";
                    return false;
                }

                configValue = ConnectionConfigValue.Boolean(boolean);
                break;
            case ConnectionFieldType.Credential:
                entry = null;
                error =
                    $"{Label} is secret and must be entered in the PasswordVault credential field.";
                return false;
            default:
                entry = null;
                error = $"{Label} uses an unsupported field type.";
                return false;
        }

        entry = new ConnectionConfigEntry
        {
            Key = Key,
            Value = configValue,
        };
        error = null;
        return true;
    }
}

public sealed class ProviderParameterEditor : ObservableObject
{
    private bool useProviderDefault = true;
    private string input = string.Empty;
    private bool isEnabled = true;
    private string policyMessage = string.Empty;
    private string? policyError;

    internal ProviderParameterEditor(ProviderParameterSpec spec)
    {
        Spec = spec ?? throw new ArgumentNullException(nameof(spec));
        useProviderDefault = !string.Equals(
            spec.DefaultMode,
            "explicit_required",
            StringComparison.Ordinal);
    }

    internal ProviderParameterSpec Spec { get; }

    public string Id => Spec.Id;

    public string Label => Spec.LabelKey;

    public string Description => Spec.DescriptionKey ?? string.Empty;

    public string TypeLabel =>
        CapabilityDisplayItem.Humanize(Spec.ValueType);

    public string Constraint =>
        BuildConstraint(Spec);

    public bool CanUseProviderDefault =>
        IsEnabled
        && !string.Equals(
            Spec.DefaultMode,
            "explicit_required",
            StringComparison.Ordinal);

    public bool IsEnabled
    {
        get => isEnabled;
        private set
        {
            if (SetProperty(ref isEnabled, value))
            {
                OnPropertyChanged(nameof(CanUseProviderDefault));
                OnPropertyChanged(nameof(CanEditValue));
            }
        }
    }

    public bool CanEditValue =>
        IsEnabled && !UseProviderDefault;

    public string PolicyMessage
    {
        get => policyMessage;
        private set => SetProperty(ref policyMessage, value);
    }

    public bool UseProviderDefault
    {
        get => useProviderDefault;
        set
        {
            if (SetProperty(ref useProviderDefault, value))
            {
                OnPropertyChanged(nameof(CanEditValue));
            }
        }
    }

    public string Input
    {
        get => input;
        set => SetProperty(ref input, value);
    }

    internal void Load(ProviderParameterValue value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (string.Equals(
                value.State.State,
                "inherit_provider_default",
                StringComparison.Ordinal))
        {
            UseProviderDefault = true;
            Input = string.Empty;
            return;
        }

        UseProviderDefault = false;
        Input = FormatLiteral(
            value.State.Value,
            string.Equals(
                Spec.ValueType,
                "stop_sequence_list",
                StringComparison.Ordinal)
                ? Environment.NewLine
                : ", ");
    }

    internal bool TryBuild(
        out ProviderParameterValue? value,
        out string? error)
    {
        if (policyError is not null)
        {
            value = null;
            error = policyError;
            return false;
        }

        if (UseProviderDefault)
        {
            value = new ProviderParameterValue
            {
                ParameterId = Id,
                State = new ProviderParameterValueState
                {
                    State = "inherit_provider_default",
                },
            };
            error = null;
            return true;
        }

        if (!TryParseLiteral(Spec, Input, out var literal, out error))
        {
            value = null;
            return false;
        }

        value = new ProviderParameterValue
        {
            ParameterId = Id,
            State = new ProviderParameterValueState
            {
                State = "explicit",
                Value = literal,
            },
        };
        return true;
    }

    internal bool TryGetExplicitLiteral(
        out ProviderParameterLiteral? literal)
    {
        if (UseProviderDefault)
        {
            literal = null;
            return false;
        }
        return TryParseLiteral(
            Spec,
            Input,
            out literal,
            out _);
    }

    internal void ClearHiddenValue()
    {
        UseProviderDefault = true;
        Input = string.Empty;
    }

    internal void SetPolicy(
        bool enabled,
        string message,
        string? error)
    {
        IsEnabled = enabled;
        PolicyMessage = message;
        policyError = error;
    }

    private static string BuildConstraint(ProviderParameterSpec spec)
    {
        if (spec.AllowedValues.Count > 0)
        {
            return "Allowed: "
                + string.Join(
                    ", ",
                    spec.AllowedValues.Select(choice =>
                        FormatLiteral(choice.Value)));
        }

        if (spec.Minimum is not null
            || spec.Maximum is not null)
        {
            var minimum = spec.Minimum?.ToString(
                CultureInfo.CurrentCulture) ?? "any";
            var maximum = spec.Maximum?.ToString(
                CultureInfo.CurrentCulture) ?? "any";
            var range = $"Range: {minimum} to {maximum}";
            return spec.Step is > 0
                ? $"{range}; step {spec.Step.Value.ToString(CultureInfo.CurrentCulture)}"
                : range;
        }

        if (spec.Step is > 0)
        {
            return
                $"Step: {spec.Step.Value.ToString(CultureInfo.CurrentCulture)}";
        }

        return string.Equals(
            spec.DefaultMode,
            "provider_default",
            StringComparison.Ordinal)
            ? "Provider default is available."
            : "An explicit value is required.";
    }

    private static bool TryParseLiteral(
        ProviderParameterSpec spec,
        string input,
        out ProviderParameterLiteral? literal,
        out string? error)
    {
        var normalized = input.Trim();
        object parsed;
        switch (spec.ValueType)
        {
            case "boolean":
                if (!bool.TryParse(normalized, out var boolean))
                {
                    return Fail(
                        $"{spec.LabelKey} must be true or false.",
                        out literal,
                        out error);
                }

                parsed = boolean;
                break;
            case "integer":
                if (!long.TryParse(
                        normalized,
                        NumberStyles.Integer,
                        CultureInfo.InvariantCulture,
                        out var integer))
                {
                    return Fail(
                        $"{spec.LabelKey} must be a whole number.",
                        out literal,
                        out error);
                }

                if (!WithinRange(spec, integer))
                {
                    return Fail(
                        $"{spec.LabelKey} is outside its supported range.",
                        out literal,
                        out error);
                }
                if (!MatchesStep(spec, integer))
                {
                    return Fail(
                        $"{spec.LabelKey} must use the provider-supported step.",
                        out literal,
                        out error);
                }

                parsed = integer;
                break;
            case "number":
                if (!double.TryParse(
                        normalized,
                        NumberStyles.Float,
                        CultureInfo.InvariantCulture,
                        out var number)
                    || !double.IsFinite(number))
                {
                    return Fail(
                        $"{spec.LabelKey} must be a finite number.",
                        out literal,
                        out error);
                }

                if (!WithinRange(spec, number))
                {
                    return Fail(
                        $"{spec.LabelKey} is outside its supported range.",
                        out literal,
                        out error);
                }
                if (!MatchesStep(spec, number))
                {
                    return Fail(
                        $"{spec.LabelKey} must use the provider-supported step.",
                        out literal,
                        out error);
                }

                parsed = number;
                break;
            case "enum":
            case "tool_policy":
                if (!IsAllowed(spec, normalized))
                {
                    return Fail(
                        $"{spec.LabelKey} is not one of the provider-supported values.",
                        out literal,
                        out error);
                }

                parsed = normalized;
                break;
            case "string_list":
                parsed = SplitValues(normalized, ',');
                break;
            case "stop_sequence_list":
                parsed = SplitValues(input, '\n');
                break;
            case "json_schema":
                try
                {
                    using var document = JsonDocument.Parse(normalized);
                    if (document.RootElement.ValueKind !=
                        JsonValueKind.Object)
                    {
                        return Fail(
                            $"{spec.LabelKey} must be a JSON object.",
                            out literal,
                            out error);
                    }
                }
                catch (JsonException)
                {
                    return Fail(
                        $"{spec.LabelKey} must be valid JSON.",
                        out literal,
                        out error);
                }

                parsed = normalized;
                break;
            case "string":
                parsed = normalized;
                break;
            default:
                return Fail(
                    $"{spec.LabelKey} uses an unsupported parameter type.",
                    out literal,
                    out error);
        }

        if (string.Equals(
                spec.DefaultMode,
                "explicit_required",
                StringComparison.Ordinal)
            && parsed is string text
            && string.IsNullOrWhiteSpace(text))
        {
            return Fail(
                $"{spec.LabelKey} requires a non-empty explicit value.",
                out literal,
                out error);
        }
        if (string.Equals(
                spec.DefaultMode,
                "explicit_required",
                StringComparison.Ordinal)
            && parsed is Array array
            && array.Length == 0)
        {
            return Fail(
                $"{spec.LabelKey} requires at least one explicit value.",
                out literal,
                out error);
        }

        literal = new ProviderParameterLiteral
        {
            Type = spec.ValueType,
            Value = JsonSerializer.SerializeToElement(parsed),
        };
        error = null;
        return true;
    }

    private static bool WithinRange(
        ProviderParameterSpec spec,
        double value)
    {
        return (spec.Minimum is null || value >= spec.Minimum)
            && (spec.Maximum is null || value <= spec.Maximum);
    }

    private static bool MatchesStep(
        ProviderParameterSpec spec,
        double value)
    {
        if (spec.Step is null or <= 0)
        {
            return true;
        }
        var units =
            (value - (spec.Minimum ?? 0)) / spec.Step.Value;
        var distance = Math.Abs(units - Math.Round(units));
        var tolerance =
            1e-9 * Math.Max(1, Math.Abs(units));
        return distance <= tolerance;
    }

    private static bool IsAllowed(
        ProviderParameterSpec spec,
        string value)
    {
        if (spec.AllowedValues.Count == 0)
        {
            return spec.ValueType == "tool_policy"
                ? value is "none" or "auto" or "required"
                : value.Length > 0;
        }

        return spec.AllowedValues.Any(choice =>
            string.Equals(
                FormatLiteral(choice.Value),
                value,
                StringComparison.Ordinal));
    }

    private static string[] SplitValues(
        string value,
        char separator)
    {
        return value
            .Split(
                separator,
                StringSplitOptions.RemoveEmptyEntries
                    | StringSplitOptions.TrimEntries);
    }

    private static string FormatLiteral(
        ProviderParameterLiteral? literal,
        string arraySeparator = ", ")
    {
        if (literal is null)
        {
            return string.Empty;
        }

        return literal.Value.ValueKind switch
        {
            JsonValueKind.String => literal.Value.GetString()
                ?? string.Empty,
            JsonValueKind.Array => string.Join(
                arraySeparator,
                literal.Value.EnumerateArray().Select(item =>
                    item.GetString() ?? item.GetRawText())),
            _ => literal.Value.GetRawText(),
        };
    }

    private static bool Fail(
        string message,
        out ProviderParameterLiteral? literal,
        out string? error)
    {
        literal = null;
        error = message;
        return false;
    }
}

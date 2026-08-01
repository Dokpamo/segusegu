using System.Xml.Linq;

namespace Lorepia.Native.Tests;

public sealed class WindowsProviderSourceContractTests
{
    [Fact]
    public void PasswordVaultResourceAndConnectionIdentityRemainStable()
    {
        var source = File.ReadAllText(SourcePath(
            "Lorepia.App",
            "Platform",
            "PasswordVaultCredentialStore.cs"));

        Assert.Contains(
            """
            private const string Resource = "LorePia.ProviderCredential";
            """,
            source,
            StringComparison.Ordinal);
        Assert.Contains(
            "vault.Retrieve(Resource, connectionId)",
            source,
            StringComparison.Ordinal);
        Assert.Contains(
            "new PasswordCredential(",
            source,
            StringComparison.Ordinal);
    }

    [Fact]
    public void ProviderSettingsExposeStableAutomationIds()
    {
        var document = XDocument.Load(SourcePath(
            "Lorepia.App",
            "Pages",
            "SettingsPage.xaml"));
        var ids = document
            .Descendants()
            .Attributes()
            .Where(attribute =>
                attribute.Name.LocalName ==
                "AutomationProperties.AutomationId")
            .Select(attribute => attribute.Value)
            .ToList();

        Assert.Equal(ids.Count, ids.Distinct(StringComparer.Ordinal).Count());
        AssertRequired(
            ids,
            "ProviderSetupMode",
            "ProviderTemplate",
            "ProviderConnection",
            "ProviderCredential",
            "ApproveCredentialOrigin",
            "StartProviderDiscovery",
            "CancelProviderDiscovery",
            "ProviderAssistantModelRoute",
            "ProviderAssistantModelRouteSummary",
            "ProviderAssistantGrantReview",
            "ApproveProviderAssistantGrant",
            "DeclineProviderAssistantGrant",
            "AcceptProviderAssistantDraft",
            "ReviseProviderAssistantDraft",
            "RetryProviderAssistant",
            "RefreshProviderModels",
            "ApproveProviderModelSync",
            "CancelProviderModelSync",
            "ProviderModelRoute",
            "ProviderCapabilities",
            "GenerationPreset",
            "ProviderParameterEditors",
            "RedactedRequestPreview",
            "RefreshRedactedRequestPreview",
            "SaveDefaultGenerationTarget",
            "ProviderCatalogStatus",
            "ReviewSignedProviderCatalog",
            "ActivateSignedProviderCatalog",
            "ReviewProviderCatalogDiff",
            "PrepareProviderCatalogRollback",
            "ActivateProviderCatalogRollback");
    }

    [Fact]
    public void CredentialAndCurlControlsAreClearedAfterUse()
    {
        var page = File.ReadAllText(SourcePath(
            "Lorepia.App",
            "Pages",
            "SettingsPage.xaml.cs"));
        var viewModel = File.ReadAllText(SourcePath(
            "Lorepia.App",
            "ViewModels",
            "SettingsViewModel.cs"));

        Assert.Contains(
            "CredentialBox.Password = string.Empty;",
            page,
            StringComparison.Ordinal);
        Assert.Contains(
            "CurlExampleBox.Text = string.Empty;",
            page,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            "private string curl",
            viewModel,
            StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(
            "public string Curl",
            viewModel,
            StringComparison.Ordinal);
    }

    [Fact]
    public void OpaqueReasoningContinuityUsesCredentialPolicyEnablement()
    {
        var document = XDocument.Load(SourcePath(
            "Lorepia.App",
            "Pages",
            "SettingsPage.xaml"));
        var control = document.Descendants().Single(element =>
            element.Attributes().Any(attribute =>
                attribute.Name.LocalName ==
                    "AutomationProperties.AutomationId"
                && attribute.Value == "PreserveOpaqueReasoning"));

        Assert.Equal(
            "{x:Bind ViewModel.CanPreserveOpaqueReasoningState, Mode=OneWay}",
            control.Attributes().Single(attribute =>
                attribute.Name.LocalName == "IsEnabled").Value);
    }

    [Theory]
    [InlineData(
        "SaveProviderConnection",
        "{x:Bind ViewModel.CanSaveConnection, Mode=OneWay}")]
    [InlineData(
        "RemoveProviderCredential",
        "{x:Bind ViewModel.CanRemoveSelectedCredential, Mode=OneWay}")]
    [InlineData(
        "NewProviderConnection",
        "{x:Bind ViewModel.CanChangeProviderSelection, Mode=OneWay}")]
    [InlineData(
        "ProviderSetupMode",
        "{x:Bind ViewModel.CanChangeProviderSelection, Mode=OneWay}")]
    [InlineData(
        "ProviderTemplate",
        "{x:Bind ViewModel.CanChooseProviderTemplate, Mode=OneWay}")]
    [InlineData(
        "ProviderConnection",
        "{x:Bind ViewModel.CanChangeProviderSelection, Mode=OneWay}")]
    [InlineData(
        "RefreshProviderModels",
        "{x:Bind ViewModel.CanRefreshModels, Mode=OneWay}")]
    [InlineData(
        "ApproveProviderModelSync",
        "{x:Bind ViewModel.CanApproveModelSync, Mode=OneWay}")]
    [InlineData(
        "CancelProviderModelSync",
        "{x:Bind ViewModel.CanCancelModelSync, Mode=OneWay}")]
    [InlineData(
        "StartProviderDiscovery",
        "{x:Bind ViewModel.CanStartDiscovery, Mode=OneWay}")]
    [InlineData(
        "SaveDefaultGenerationTarget",
        "{x:Bind ViewModel.CanSaveAppSettings, Mode=OneWay}")]
    [InlineData(
        "ProviderAssistantConsent",
        "{x:Bind ViewModel.CanEnableAssistantRequest, Mode=OneWay}")]
    [InlineData(
        "ProviderAssistantModelRoute",
        "{x:Bind ViewModel.CanEditAssistantModelRoute, Mode=OneWay}")]
    [InlineData(
        "ApproveProviderAssistantGrant",
        "{x:Bind ViewModel.CanApproveAssistantGrant, Mode=OneWay}")]
    [InlineData(
        "DeclineProviderAssistantGrant",
        "{x:Bind ViewModel.CanDeclineAssistantGrant, Mode=OneWay}")]
    public void ProviderActionButtonsUseOperationAwareEnablement(
        string automationId,
        string expectedBinding)
    {
        var document = XDocument.Load(SourcePath(
            "Lorepia.App",
            "Pages",
            "SettingsPage.xaml"));
        var control = document.Descendants().Single(element =>
            element.Attributes().Any(attribute =>
                attribute.Name.LocalName ==
                    "AutomationProperties.AutomationId"
                && attribute.Value == automationId));

        Assert.Equal(
            expectedBinding,
            control.Attributes().Single(attribute =>
                attribute.Name.LocalName == "IsEnabled").Value);
    }

    private static void AssertRequired(
        IReadOnlyCollection<string> actual,
        params string[] required)
    {
        foreach (var id in required)
        {
            Assert.Contains(id, actual);
        }
    }

    private static string SourcePath(params string[] components)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null
               && !File.Exists(Path.Combine(
                   directory.FullName,
                   "Lorepia.sln")))
        {
            directory = directory.Parent;
        }

        if (directory is null)
        {
            throw new DirectoryNotFoundException(
                "Could not locate the Windows source root.");
        }

        return Path.Combine(
            [directory.FullName, .. components]);
    }
}

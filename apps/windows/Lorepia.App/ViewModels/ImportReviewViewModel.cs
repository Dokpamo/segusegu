using Lorepia.App.Platform;
using Lorepia.Native;

namespace Lorepia.App.ViewModels;

public sealed class ImportReviewViewModel : ObservableObject
{
    private readonly CoreClient core;
    private string selectedFileName = "No file selected";
    private string selectedFilePath = string.Empty;
    private string selectedFileSize = string.Empty;
    private string displayName = "—";
    private string description = "—";
    private string contentKind = "—";
    private string storageEstimate = "—";
    private string warnings = "None";
    private string blockedReasons = "None";
    private string representativeImage = "None";
    private string unsupportedOptionalFields = "None";
    private string reviewStatus =
        "Select a local character card or CHARX package for Rust inspection.";
    private string? inspectionId;
    private bool inspectionAllowed;
    private bool isBusy;

    internal ImportReviewViewModel(CoreClient core)
    {
        this.core = core;
    }

    public string SelectedFileName
    {
        get => selectedFileName;
        private set => SetProperty(ref selectedFileName, value);
    }

    public string SelectedFilePath
    {
        get => selectedFilePath;
        private set => SetProperty(ref selectedFilePath, value);
    }

    public string SelectedFileSize
    {
        get => selectedFileSize;
        private set => SetProperty(ref selectedFileSize, value);
    }

    public string DisplayName
    {
        get => displayName;
        private set => SetProperty(ref displayName, value);
    }

    public string Description
    {
        get => description;
        private set => SetProperty(ref description, value);
    }

    public string ContentKind
    {
        get => contentKind;
        private set => SetProperty(ref contentKind, value);
    }

    public string StorageEstimate
    {
        get => storageEstimate;
        private set => SetProperty(ref storageEstimate, value);
    }

    public string Warnings
    {
        get => warnings;
        private set => SetProperty(ref warnings, value);
    }

    public string BlockedReasons
    {
        get => blockedReasons;
        private set => SetProperty(ref blockedReasons, value);
    }

    public string RepresentativeImage
    {
        get => representativeImage;
        private set => SetProperty(ref representativeImage, value);
    }

    public string UnsupportedOptionalFields
    {
        get => unsupportedOptionalFields;
        private set => SetProperty(ref unsupportedOptionalFields, value);
    }

    public string ReviewStatus
    {
        get => reviewStatus;
        private set => SetProperty(ref reviewStatus, value);
    }

    public bool IsBusy
    {
        get => isBusy;
        private set
        {
            if (SetProperty(ref isBusy, value))
            {
                OnPropertyChanged(nameof(CanApprove));
                OnPropertyChanged(nameof(CanChooseFile));
            }
        }
    }

    public bool CanApprove =>
        inspectionId is not null && inspectionAllowed && !IsBusy;

    public bool CanChooseFile => !IsBusy;

    internal async Task InspectAsync(StagedTransportFile staged)
    {
        ArgumentNullException.ThrowIfNull(staged);
        await DiscardAsync();

        IsBusy = true;
        SelectedFileName = staged.Name;
        SelectedFilePath = staged.Path;
        SelectedFileSize = BoundedStagingCopier.FormatBytes(
            checked((long)staged.Size));
        ReviewStatus = "Rust is inspecting the staged snapshot…";

        try
        {
            var inspection = await Task.Run(() =>
                core.InspectImport(staged.Path));
            inspectionId = inspection.Id;
            inspectionAllowed = inspection.IsAllowed;
            DisplayName = inspection.DisplayName;
            Description = string.IsNullOrWhiteSpace(inspection.Description)
                ? "No description"
                : inspection.Description;
            ContentKind = inspection.Kind;
            StorageEstimate =
                $"{BoundedStagingCopier.FormatBytes(checked((long)inspection.EstimatedStoredSize))} · {inspection.AssetCount} asset(s)";
            Warnings = inspection.Warnings.Count == 0
                ? "None"
                : string.Join(
                    Environment.NewLine,
                    inspection.Warnings.Select(warning =>
                        $"{warning.Code}: {warning.Message}"));
            BlockedReasons = inspection.BlockedReasons.Count == 0
                ? "None"
                : string.Join(Environment.NewLine, inspection.BlockedReasons);
            RepresentativeImage = inspection.RepresentativeImage is { } image
                ? $"{image.LogicalAssetId} · {image.MediaType} · " +
                  BoundedStagingCopier.FormatBytes(
                      image.SizeBytes > (ulong)long.MaxValue
                          ? long.MaxValue
                          : (long)image.SizeBytes)
                : "None";
            UnsupportedOptionalFields =
                inspection.UnsupportedOptionalFields.Count == 0
                    ? "None"
                    : string.Join(
                        Environment.NewLine,
                        inspection.UnsupportedOptionalFields);
            ReviewStatus = inspection.IsAllowed
                ? "Inspection complete. Review the details before approving the import."
                : "Import is blocked. Nothing has been committed.";
        }
        catch (Exception exception)
        {
            ResetInspection();
            ReviewStatus = $"Inspection failed: {exception.Message}";
        }
        finally
        {
            BoundedStagingCopier.TryDelete(staged.Path);
            SelectedFilePath = string.Empty;
            IsBusy = false;
            OnPropertyChanged(nameof(CanApprove));
        }
    }

    internal async Task<CharacterSummary?> ApproveAsync()
    {
        if (!CanApprove || inspectionId is null)
        {
            return null;
        }

        IsBusy = true;
        ReviewStatus = "Committing the approved import…";
        var approvedId = inspectionId;
        try
        {
            var character = await Task.Run(() =>
                core.CommitImport(approvedId));
            inspectionId = null;
            inspectionAllowed = false;
            ReviewStatus = $"Imported {character.Name}.";
            return character;
        }
        catch (Exception exception)
        {
            ReviewStatus = $"Import failed: {exception.Message}";
            return null;
        }
        finally
        {
            IsBusy = false;
            OnPropertyChanged(nameof(CanApprove));
        }
    }

    internal async Task DiscardAsync()
    {
        var pendingId = inspectionId;
        inspectionId = null;
        inspectionAllowed = false;
        OnPropertyChanged(nameof(CanApprove));
        if (pendingId is null)
        {
            return;
        }

        try
        {
            await Task.Run(() => core.DiscardImport(pendingId));
        }
        catch (CoreInteropException exception)
            when (exception.Code == "not_found")
        {
            // Commit or recovery may already have removed the snapshot.
        }
    }

    internal void BeginStaging(string fileName)
    {
        IsBusy = true;
        SelectedFileName = fileName;
        SelectedFilePath = string.Empty;
        SelectedFileSize = string.Empty;
        ReviewStatus = "Copying into bounded app-owned transport staging…";
    }

    internal void SetFailure(string message)
    {
        IsBusy = false;
        ReviewStatus = message;
    }

    internal void ClearView()
    {
        ResetInspection();
        SelectedFileName = "No file selected";
        SelectedFilePath = string.Empty;
        SelectedFileSize = string.Empty;
        ReviewStatus =
            "Select a local character card or CHARX package for Rust inspection.";
    }

    private void ResetInspection()
    {
        inspectionId = null;
        inspectionAllowed = false;
        DisplayName = "—";
        Description = "—";
        ContentKind = "—";
        StorageEstimate = "—";
        Warnings = "None";
        BlockedReasons = "None";
        RepresentativeImage = "None";
        UnsupportedOptionalFields = "None";
        OnPropertyChanged(nameof(CanApprove));
    }
}

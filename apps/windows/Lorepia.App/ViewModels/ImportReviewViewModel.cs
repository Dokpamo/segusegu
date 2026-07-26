namespace Lorepia.App.ViewModels;

public sealed class ImportReviewViewModel : ObservableObject
{
    private string selectedFileName = "No file selected";
    private string selectedFilePath = string.Empty;
    private string selectedFileSize = string.Empty;
    private string reviewStatus =
        "Select a package. Windows will copy it into app staging; Rust remains responsible for inspection.";
    private bool hasSelection;
    private bool isBusy;

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

    public string ReviewStatus
    {
        get => reviewStatus;
        private set => SetProperty(ref reviewStatus, value);
    }

    public bool HasSelection
    {
        get => hasSelection;
        private set => SetProperty(ref hasSelection, value);
    }

    public bool IsBusy
    {
        get => isBusy;
        private set => SetProperty(ref isBusy, value);
    }

    public void BeginStaging()
    {
        IsBusy = true;
        ReviewStatus = "Copying the selected file to app staging…";
    }

    public void SetStagedFile(string name, string path, ulong size)
    {
        SelectedFileName = name;
        SelectedFilePath = path;
        SelectedFileSize = FormatBytes(size);
        HasSelection = true;
        IsBusy = false;
        ReviewStatus =
            "Staging complete. Final approval remains disabled until Rust inspection is added to the public C ABI.";
    }

    public void SetFailure(string message)
    {
        IsBusy = false;
        ReviewStatus = message;
    }

    public void Clear()
    {
        SelectedFileName = "No file selected";
        SelectedFilePath = string.Empty;
        SelectedFileSize = string.Empty;
        HasSelection = false;
        IsBusy = false;
        ReviewStatus =
            "Select a package. Windows will copy it into app staging; Rust remains responsible for inspection.";
    }

    private static string FormatBytes(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        var value = (double)bytes;
        var unitIndex = 0;

        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return $"{value:0.##} {units[unitIndex]}";
    }
}

using Lorepia.App.Platform;
using Lorepia.Native;
using Microsoft.UI.Xaml;
using System.Collections.ObjectModel;

namespace Lorepia.App.ViewModels;

public sealed class LibraryViewModel : ObservableObject
{
    private string status = "Loading local characters…";
    private bool isLoading;
    private Visibility emptyStateVisibility = Visibility.Visible;

    public ObservableCollection<CharacterSummary> Characters { get; } = [];

    public string EmptyStateTitle => "Your library is empty";

    public string EmptyStateDescription =>
        "Choose a local character package to begin a safe import review.";

    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public bool IsLoading
    {
        get => isLoading;
        private set => SetProperty(ref isLoading, value);
    }

    public Visibility EmptyStateVisibility
    {
        get => emptyStateVisibility;
        private set => SetProperty(ref emptyStateVisibility, value);
    }

    public async Task LoadAsync()
    {
        if (IsLoading)
        {
            return;
        }

        IsLoading = true;
        Status = "Loading local characters…";

        try
        {
            var characters = await Task.Run(() =>
            {
                using var client = CoreClient.Open(
                    WindowsDataRoot.GetOrCreate());
                return client.ListCharacters();
            });

            Characters.Clear();
            foreach (var character in characters)
            {
                Characters.Add(character);
            }

            EmptyStateVisibility = Characters.Count == 0
                ? Visibility.Visible
                : Visibility.Collapsed;
            Status = Characters.Count == 1
                ? "1 local character"
                : $"{Characters.Count} local characters";
        }
        catch (Exception exception)
        {
            Characters.Clear();
            EmptyStateVisibility = Visibility.Visible;
            Status = $"Could not load the library: {exception.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }
}

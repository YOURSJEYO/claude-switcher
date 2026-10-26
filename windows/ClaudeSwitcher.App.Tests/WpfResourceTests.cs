using System.Threading;
using System.Windows.Controls;
using System.Windows.Media;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class WpfResourceTests
{
    [Fact]
    public async Task CompiledResources_WireStartupAndBindStatusColorsWithoutLoadingWindow()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            App? application = null;
            MainWindow? window = null;
            try
            {
                application = new App();
                // Empty Application XAML does not emit InitializeComponent;
                // exercise it when present and still detect a missing startup URI.
                typeof(App).GetMethod("InitializeComponent")?.Invoke(application, null);
                // Construction initializes compiled XAML only. Never call Run,
                // Show, or raise Loaded, which would contact the installed core.
                window = new MainWindow();
                Assert.False(window.IsLoaded);
                Assert.False(window.IsVisible);
                var grid = Assert.IsType<DataGrid>(window.FindName("ChecksGrid"));
                var column = Assert.IsType<DataGridTextColumn>(grid.Columns[0]);
                var failures = new List<string>();
                if (application.StartupUri?.OriginalString != "MainWindow.xaml")
                {
                    failures.Add("Compiled Application.StartupUri must resolve MainWindow.xaml.");
                }

                foreach (var (state, accent) in new[]
                {
                    (CheckVisualState.Ok, "#22C55E"),
                    (CheckVisualState.Warning, "#F59E0B"),
                    (CheckVisualState.Failed, "#F87171")
                })
                {
                    var text = new TextBlock
                    {
                        DataContext = new CheckRow("synthetic", "synthetic", "", state, "!", accent, false),
                        Style = column.ElementStyle
                    };
                    text.GetBindingExpression(TextBlock.ForegroundProperty)?.UpdateTarget();
                    var expected = (Color)ColorConverter.ConvertFromString(accent);
                    if (text.Foreground is not SolidColorBrush brush || brush.Color != expected)
                    {
                        failures.Add($"Status text for {state} must bind Foreground to row Accent {accent}.");
                    }
                }

                Assert.False(window.IsLoaded);
                Assert.False(window.IsVisible);
                Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));
                completion.SetResult();
            }
            catch (Exception exception)
            {
                completion.SetException(exception);
            }
            finally
            {
                window?.Close();
                application?.Shutdown();
            }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
}

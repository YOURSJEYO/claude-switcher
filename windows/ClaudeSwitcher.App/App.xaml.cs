using System.Security.Principal;
using System.Windows;
using ClaudeSwitcher.App.Models;

namespace ClaudeSwitcher.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        var launch = AppLaunchArguments.Parse(e.Args);
        if (AppStartupPolicy.Decide(launch.SetupMode, IsElevated()) == AppStartupDecision.RefuseElevated)
        {
            StartupUri = null;
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            MessageBox.Show(
                AppStartupPolicy.ElevatedMessage,
                "需要普通用户权限",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            Shutdown(1);
            return;
        }

        if (!launch.SetupMode)
        {
            base.OnStartup(e);
            return;
        }

        StartupUri = null;
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var wizard = new SetupWizardWindow();
        wizard.Closed += (_, _) =>
        {
            if (wizard.SetupCompleted || wizard.SetupMayStillBeRunning)
            {
                var window = wizard.SetupMayStillBeRunning
                    ? new MainWindow(wizard.WaitForPendingApplyAsync())
                    : new MainWindow();
                MainWindow = window;
                ShutdownMode = ShutdownMode.OnLastWindowClose;
                window.Show();
            }
            else
            {
                Shutdown();
            }
        };
        MainWindow = wizard;
        wizard.Show();
    }

    private static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }
}

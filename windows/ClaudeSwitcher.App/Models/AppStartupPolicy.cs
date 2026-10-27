namespace ClaudeSwitcher.App.Models;

public enum AppStartupDecision
{
    NormalWindow,
    SetupWizard,
    RefuseElevated
}

public static class AppStartupPolicy
{
    public static AppStartupDecision Decide(bool setupMode, bool elevated)
    {
        if (elevated)
        {
            return AppStartupDecision.RefuseElevated;
        }

        return setupMode ? AppStartupDecision.SetupWizard : AppStartupDecision.NormalWindow;
    }

    public static string ElevatedMessage =>
        "Claude 切换器不能以管理员身份运行。请关闭本应用，并从普通桌面会话重新启动后再继续；配置时的 UAC 由安装器单独请求。";
}

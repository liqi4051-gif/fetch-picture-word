// fetch-picture-word 启动器
//
// 作用：双击后无控制台窗口地拉起同目录（或 src/）下的 app.ps1。
// 单独做成 exe 是为了让它在资源管理器/任务栏里像一个正常软件：
// 有图标、有固定的 AppUserModelID（任务栏不会跟 PowerShell 混在一起），
// 并且按显示器 DPI 感知，避免高分屏下窗口发虚。

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// 资源管理器「属性 → 详细信息」里看到的版本与版权信息。
// 改版本号时记得同步 desktop\install.ps1 里的 DisplayVersion。
[assembly: AssemblyTitle("提取图片文字")]
[assembly: AssemblyProduct("FetchPictureWord")]
[assembly: AssemblyDescription("把图片里的文字读出来（Windows 自带 OCR，离线运行）")]
[assembly: AssemblyCompany("fetch-picture-word contributors")]
[assembly: AssemblyCopyright("Copyright (c) 2026 fetch-picture-word contributors")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Program
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [STAThread]
    private static int Main(string[] args)
    {
        try { SetCurrentProcessExplicitAppUserModelID("FetchPictureWord.Desktop"); }
        catch { }
        try { SetProcessDPIAware(); }
        catch { }

        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(baseDirectory, "app.ps1");
        if (!File.Exists(script))
        {
            script = Path.Combine(baseDirectory, Path.Combine("src", "app.ps1"));
        }
        if (!File.Exists(script))
        {
            MessageBox.Show(
                "找不到 app.ps1。\r\n请把本程序放在软件目录里（和 app.ps1 或 src\\app.ps1 在一起）。",
                "提取图片文字", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell");
        powershell = Path.Combine(powershell, "v1.0");
        powershell = Path.Combine(powershell, "powershell.exe");
        if (!File.Exists(powershell)) { powershell = "powershell.exe"; }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powershell;
        startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"";
        startInfo.WorkingDirectory = Path.GetDirectoryName(script);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;

        try
        {
            Process process = Process.Start(startInfo);
            if (process == null)
            {
                MessageBox.Show("启动失败：无法创建进程。", "提取图片文字", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 3;
            }
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show("启动失败：" + exception.Message, "提取图片文字", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 4;
        }
    }
}

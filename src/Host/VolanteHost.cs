// Volante WebView2 host - compiled into Volante.exe by tools\Build-Exe.ps1.
// A no-console Windows app (admin manifest = auto-UAC) that renders the redesigned
// web UI (src\WebUI) in Edge WebView2 and bridges it to the PowerShell engine.
//
// Phase 0: render the UI (mock data). The JS<->PowerShell bridge is wired in Phase 1
// (see the OnWebMessage TODO below).
using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

static class VolanteHostApp
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            Application.Run(new VolanteForm());
        }
        catch (Exception ex)
        {
            MessageBox.Show("Volante failed to start:\n" + ex.Message,
                "Volante", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

class VolanteForm : Form
{
    readonly WebView2 _web;
    readonly object _psLock = new object();
    Runspace _rs;

    public VolanteForm()
    {
        Text = "Volante";
        Width = 1340;
        Height = 900;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = System.Drawing.Color.FromArgb(15, 15, 17);
        _web = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(_web);
        Load += async (s, e) => await InitAsync();
    }

    async Task InitAsync()
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        string webui = Path.Combine(exeDir, @"src\WebUI");
        if (!File.Exists(Path.Combine(webui, "index.html")))
        {
            MessageBox.Show(
                "Volante's UI files weren't found next to the app.\n" +
                "Keep Volante.exe in the Volante folder (with the 'src' folder).\n\n" +
                "Looked in: " + webui,
                "Volante", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
            return;
        }

        // WebView2 needs a writable user-data folder; Program Files is read-only.
        string udf = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Volante", "WebView2");
        Directory.CreateDirectory(udf);

        var env = await CoreWebView2Environment.CreateAsync(null, udf, null);
        await _web.EnsureCoreWebView2Async(env);
        var core = _web.CoreWebView2;

        // Serve src\WebUI as a real https origin so module/fetch loading behaves.
        core.SetVirtualHostNameToFolderMapping(
            "volante.app", webui, CoreWebView2HostResourceAccessKind.Allow);

        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDevToolsEnabled = true; // handy during development

        // Bring up the in-process PowerShell engine off the UI thread, then bridge.
        string enginePath = Path.Combine(exeDir, @"src\Engine\Optimizer.Engine.psm1");
        await Task.Run(() => InitRunspace(enginePath));
        core.WebMessageReceived += OnWebMessage;

        core.Navigate("https://volante.app/index.html");
    }

    // One shared runspace with the engine module imported. PowerShell pipelines are
    // created per-call against it under a lock (a runspace can't run concurrently).
    void InitRunspace(string enginePath)
    {
        var iss = InitialSessionState.CreateDefault();
        _rs = RunspaceFactory.CreateRunspace(iss);
        _rs.Open();
        using (var ps = PowerShell.Create())
        {
            ps.Runspace = _rs;
            ps.AddScript(
                "Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction SilentlyContinue; " +
                "Import-Module -Name '" + enginePath.Replace("'", "''") + "' -Force");
            ps.Invoke();
        }
    }

    // UI message -> engine (background thread) -> reply on the UI thread.
    void OnWebMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string raw;
        try { raw = e.TryGetWebMessageAsString(); }
        catch { return; }
        if (string.IsNullOrEmpty(raw)) return;

        Task.Run(() =>
        {
            string result = Dispatch(raw);
            try
            {
                BeginInvoke((Action)(() =>
                {
                    try { _web.CoreWebView2.PostWebMessageAsString(result); }
                    catch { }
                }));
            }
            catch { }
        });
    }

    string Dispatch(string messageJson)
    {
        lock (_psLock)
        {
            try
            {
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = _rs;
                    ps.AddCommand("Invoke-VolanteCommand").AddParameter("Message", messageJson);
                    var output = ps.Invoke();
                    foreach (var o in output)
                        if (o != null) return o.ToString();
                    return "{\"ok\":false,\"error\":\"no response from engine\"}";
                }
            }
            catch (Exception ex)
            {
                return "{\"ok\":false,\"error\":" + JsonStr(ex.Message) + "}";
            }
        }
    }

    static string JsonStr(string s)
    {
        if (s == null) return "\"\"";
        var sb = new System.Text.StringBuilder("\"");
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default: sb.Append(c); break;
            }
        }
        return sb.Append('"').ToString();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        base.OnFormClosed(e);
        try { if (_rs != null) _rs.Dispose(); } catch { }
    }
}

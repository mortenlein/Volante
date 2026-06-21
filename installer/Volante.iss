; Volante installer script (Inno Setup 6).
; Build with:  powershell -File tools\Build-Installer.ps1
; or directly: "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\Volante.iss

#define AppName "Volante"
#define AppVersion "1.0.0"
#define AppPublisher "Volante"
#define AppExe "Volante.exe"

[Setup]
; A stable, unique AppId so upgrades/uninstall work across versions.
AppId={{B6E6F3A2-1C7E-4E8E-9C0E-7E2A6C3D9A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
OutputDir=..\dist
OutputBaseFilename=Volante-Setup-{#AppVersion}
SetupIconFile=..\assets\volante.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Installs to Program Files, so admin rights are required.
PrivilegesRequired=admin

[Files]
Source: "..\Volante.exe"; DestDir: "{app}"; Flags: ignoreversion
; WebView2 SDK DLLs must sit next to the exe (managed assemblies + native loader).
Source: "..\lib\webview2\Microsoft.Web.WebView2.Core.dll";     DestDir: "{app}"; Flags: ignoreversion
Source: "..\lib\webview2\Microsoft.Web.WebView2.WinForms.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\lib\webview2\WebView2Loader.dll";                  DestDir: "{app}"; Flags: ignoreversion
Source: "..\Volante.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Optimize.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\*";    DestDir: "{app}\src";    Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\config\*"; DestDir: "{app}\config"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";           Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";     Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName} now"; Flags: nowait postinstall skipifsilent


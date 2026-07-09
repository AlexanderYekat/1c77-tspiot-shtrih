; Installation script for proxy service
#define MyAppName "cto_csharp_proxyfmu"
#define MyAppVersion "4.0"
#define MyAppPublisher "CTO CSharp"
#define MyAppExeName "cto_csharp_proxyfmu.exe"

[Setup]
; Unique application identifier for Windows
AppId={{B8F62C26-D0A9-4F19-9B7C-3A5E89C7B5E9}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://cto-ksm.ru
AppSupportURL=https://cto-ksm.ru
AppUpdatesURL=https://cto-ksm.ru
DefaultDirName={autopf}\CTO_CSHARP\{#MyAppName}
DefaultGroupName=CTO CSharp\{#MyAppName}
SetupIconFile=static\logo.ico
UninstallDisplayIcon={app}\logo.ico
OutputDir=output
OutputBaseFilename=cto_csharp_proxyfmu_setup
Compression=lzma
SolidCompression=yes
; Administrator rights required for service installation
PrivilegesRequired=admin
; Minimum supported Windows version
MinVersion=6.1sp1

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Основной исполняемый файл и зависимости self-contained сборки
Source: "for_build\proxy\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"
; Статика настроек (актуальная версия из репозитория)
Source: "static\*"; DestDir: "{app}\static"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "for_build\proxy\settings.url"; DestDir: "{app}"; Flags: ignoreversion
Source: "static\logo.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "static\logo.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Create Start Menu shortcuts
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\logo.ico"
Name: "{group}\Settings {#MyAppName}"; Filename: "http://localhost:2579"; IconFilename: "{app}\logo.ico"
;Name: "{group}\site CTO KSM"; Filename: "https://cto-ksm.ru"; IconFilename: "{app}\logo.ico"
Name: "{commondesktop}\Settings {#MyAppName}"; Filename: "http://localhost:2579"; IconFilename: "{app}\logo.ico"

[Run]
; Install and start service after installation
Filename: "{app}\{#MyAppExeName}"; Parameters: "install"; Flags: runhidden waituntilterminated; StatusMsg: "Installing service..."
Filename: "{app}\{#MyAppExeName}"; Parameters: "start"; Flags: runhidden waituntilterminated; StatusMsg: "Starting service..."
; Open settings page after installation
Filename: "{sys}\cmd.exe"; Parameters: "/c start http://localhost:2579"; Flags: nowait postinstall skipifsilent; Description: "Open settings page"

[UninstallRun]
; Stop and remove service during uninstallation
Filename: "{app}\{#MyAppExeName}"; Parameters: "stop"; Flags: runhidden waituntilterminated; RunOnceId: "StopService"
Filename: "{app}\{#MyAppExeName}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallService"

[Code]
// Function to check if service is running before uninstallation
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  // Try to stop service before uninstallation
  Exec(ExpandConstant('{app}\{#MyAppExeName}'), 'stop', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  // Give service time to stop
  Sleep(2000);
end;

// Function to check before installation
function InitializeSetup(): Boolean;
begin
  Result := True;
  // Additional pre-installation checks can be added here
end;

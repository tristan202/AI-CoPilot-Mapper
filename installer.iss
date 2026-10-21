; Inno Setup-script til AI Copilot Mapper
; Byg med build.cmd (kompilerer programmet til build\ og laver installeren i dist\)

#define AppName      "AI Copilot Mapper"
#ifndef AppVersion
  #define AppVersion "1.6.2"  ; build.cmd sender versionen med via /DAppVersion
#endif
#define AppPublisher "tristan202"
#define AppURL       "https://github.com/tristan202/AI-CoPilot-Mapper"
#define AppExe       "AICopilotMapper.exe"

[Setup]
; AppId er uaendret fra tidligere installere, saa en ny version opgraderer den gamle
AppId={{A1B2C3D4-E5F6-4321-8765-ABCDEF123456}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; programmet bruger denne mutex til "kun én instans", saa installeren kan se om det koerer
; (Global\-udgaven er fra versioner foer 1.6.1)
AppMutex=AICopilotMapper_Unique_ID,Global\AICopilotMapper_Unique_ID
CloseApplications=yes
OutputDir=dist
OutputBaseFilename=AICopilotMapper-{#AppVersion}-setup
SetupIconFile=aicopilotmapper.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "danish"; MessagesFile: "compiler:Languages\Danish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "swedish"; MessagesFile: "compiler:Languages\Swedish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
; sprogfiler (DA.lng, EN.lng ...) - programmet finder dem ved siden af exe-filen
Source: "*.lng"; DestDir: "{app}"; Flags: ignoreversion
; profilskabelon - overskrives ikke, saa brugerens egne profiler bevares ved opgradering
Source: "AICopilotMapper_profiles.ini"; DestDir: "{app}"; Flags: onlyifdoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; fjern "Start med Windows" ved afinstallation (oprettes af programmet selv)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "AICopilotMapper"; Flags: uninsdeletevalue dontcreatekey

[UninstallDelete]
; WebView2-cache og logins fra den indbyggede browser
Type: filesandordirs; Name: "{app}\WebViewData"

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; AICopilotMapper.ini (indstillinger) bevares ved afinstallation

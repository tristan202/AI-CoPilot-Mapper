; ============================================================================
; Application: AI Copilot Mapper
; Version: 1.5.0 (Fully Localized Settings GUI)
; Description: Remaps the Windows Copilot key (or custom hotkey) to AI services.
;              Features an embedded WebView2 browser, settings UI and profiles.
; ============================================================================

EnableExplicit

; ----------------------------------------------------------------------------
; EXTERNAL API IMPORTS
; ----------------------------------------------------------------------------
Import "Kernel32.lib"
  QueryFullProcessImageNameW(hProcess.i, dwFlags.l, lpExeName.i, lpdwSize.i)
EndImport

; --- CONSTANTS ---
#AppVersion = "1.6.0"

#HOTKEY_MOD_ALT   = $01
#HOTKEY_MOD_CTRL  = $02
#HOTKEY_MOD_SHIFT = $04
#HOTKEY_MOD_WIN   = $08

; ----------------------------------------------------------------------------
; DATA STRUCTURES
; ----------------------------------------------------------------------------
Structure BrowserInfo
  Name.s
  Path.s
EndStructure

Structure AIServiceInfo
  Name.s
  URL.s
  IsCustom.i
EndStructure

Structure LangInfo
  Code.s
  Name.s
EndStructure

Structure AppProfileInfo
  Process.s
  Mode.i
  AIName.s
  AIURL.s
  LaunchMode.i
  Paused.i
EndStructure

; ----------------------------------------------------------------------------
; GLOBAL VARIABLES & LISTS
; ----------------------------------------------------------------------------
Global NewList InstalledBrowsers.BrowserInfo()
Global NewList AvailableLanguages.LangInfo()
Global NewList AIServices.AIServiceInfo()
Global NewList AppProfiles.AppProfileInfo()

Global PendingLaunchURL.s = ""
Global PendingLaunchMode.i = 0

Global IniFile.s = GetPathPart(ProgramFilename()) + "AICopilotMapper.ini"
Global ProfileFile.s = GetPathPart(ProgramFilename()) + "AICopilotMapper_profiles.ini"
Global AppPath.s = ProgramFilename()
Global BrowserPath.s = "" 
Global SelectedAI.s = "Gemini" 
Global TargetURL.s = "https://gemini.google.com"
Global AutoStart.i = 0
Global Language.s = "DA"

; Custom Hotkey
Global TriggerVK.w = $86
Global TriggerModifiers.i = 0
Global TriggerKeyName.s = "Copilot-tast"

; Operating Modes
Global ButtonMode.i = 0
Global LaunchMode.i = 0
Global UseEmbeddedBrowser.i = 1
Global MappingPaused.i = 0 

; Keyboard Hook States
Global CopilotKeyDown.i = 0 
Global ActiveRemapVKey.w = 0 
Global hMutex, hHook

; Hook capture modal state
Global RecordDlgOpen.i = 0
Global RecordedVK.w = 0
Global RecordedModifiers.i = 0
Global RecordedKeyName.s = ""

; Cached per-app profile state
Global CachedProfileActive.i = 0
Global CachedProfileMode.i = -1
Global CachedProfileLaunchMode.i = -1
Global CachedProfileAIURL.s = ""
Global CachedProfilePaused.i = -1
#ProfileCacheTimerID = 1
#ProfileCacheIntervalMs = 250

; Sprogstrenge
Global Txt_MsgBoxTitle.s, Txt_MsgBoxRunning.s
Global Txt_TrayTooltip.s, Txt_MenuAbout.s, Txt_MenuExit.s
Global Txt_AboutTitle.s, Txt_AboutText.s
Global Txt_MenuPause.s, Txt_MenuSettings.s, Txt_MenuOpenAI.s
Global Txt_ModeAI.s, Txt_ModeCTRL.s, Txt_ModeALT.s
Global Txt_LaunchApp.s, Txt_LaunchTab.s, Txt_LaunchWindow.s, Txt_LaunchDefault.s
Global Txt_CustomAINamePrompt.s, Txt_CustomAIURLPrompt.s
Global Txt_CustomAINotCustomTitle.s, Txt_CustomAINotCustomMsg.s
Global Txt_RegErrorTitle.s, Txt_RegErrorMsg.s
Global Txt_ProfileReloadedTitle.s, Txt_ProfileReloadedMsg.s

; Nye strenge for Settings & Hotkey UI
Global Txt_MenuHotkey.s, Txt_HotkeyConfigure.s, Txt_HotkeyReset.s, Txt_HotkeyCurrent.s
Global Txt_HotkeyPrompt.s, Txt_HotkeyWaiting.s, Txt_HotkeyCancel.s
Global Txt_SettingsTitle.s, Txt_FrameHotkey.s, Txt_BtnRecord.s, Txt_BtnReset.s
Global Txt_LabelButtonAction.s, Txt_FrameAI.s, Txt_BtnAddCustom.s, Txt_BtnRemoveSelected.s
Global Txt_FrameBrowser.s, Txt_MenuEmbedded.s, Txt_LabelExternalBrowser.s, Txt_MenuLaunchMode.s
Global Txt_FrameSystem.s, Txt_MenuAutoStart.s, Txt_MenuLanguage.s
Global Txt_BtnOpenProfiles.s, Txt_BtnReloadProfiles.s, Txt_BtnClose.s

; ----------------------------------------------------------------------------
; ENUMERATIONS
; ----------------------------------------------------------------------------
Enumeration #PB_Event_FirstCustomValue
  #Event_OpenCopilot
  #Event_HotkeyCaptured
EndEnumeration

Enumeration
  #AboutWin
  #About_ImageGadget
  #About_LinkGadget
  #About_TextGadget
  #About_CloseBtn
  #MainWin
  #AIWin
  #AICombo
  #AIGadget
  
  ; Settings Window & Gadgets
  #SettingsWin
  #Set_FrameKey
  #Set_KeyLabel
  #Set_BtnRecordKey
  #Set_BtnResetKey
  #Set_LabelBtnAction
  #Set_ComboMode
  #Set_FrameAI
  #Set_ComboAI
  #Set_BtnAddAI
  #Set_BtnDelAI
  #Set_FrameBrowser
  #Set_ChkEmbedded
  #Set_LabelBrowser
  #Set_ComboBrowser
  #Set_LabelLaunchMode
  #Set_ComboLaunchMode
  #Set_FrameSystem
  #Set_ChkAutoStart
  #Set_LabelLang
  #Set_ComboLang
  #Set_BtnOpenProfiles
  #Set_BtnReloadProfiles
  #Set_BtnSaveClose
  
  ; Hotkey Dialog
  #HotkeyWin
  #Hotkey_TextPrompt
  #Hotkey_TextStatus
  #Hotkey_BtnCancel
  
  ; Tray Menu
  #TrayMenu
  #TrayIcon
  #AppIcon
  #Menu_Tray_OpenAI
  #Menu_Tray_Pause
  #Menu_Tray_Settings
  #Menu_Tray_About
  #Menu_Tray_Exit
EndEnumeration

; ----------------------------------------------------------------------------
; 1. INSTANCE CHECK
; ----------------------------------------------------------------------------
Global MutexName.s = "Global\AICopilotMapper_Unique_ID"
hMutex = CreateMutex_(0, 1, @MutexName)
If GetLastError_() = 183
  MessageRequester("AI Copilot Mapper", "Programmet kører allerede (se system tray)." + Chr(10) + "The application is already running (check the system tray).", #PB_MessageRequester_Info)
  End
EndIf

; ----------------------------------------------------------------------------
; 2. HELPER FUNCTIONS
; ----------------------------------------------------------------------------
Procedure.i StartsWithProtocol(Text.s)
  Protected L.s = LCase(Text)
  If FindString(L, "://") > 0 : ProcedureReturn 1 : EndIf
  ProcedureReturn 0
EndProcedure

Procedure.i IsAllowedScheme(URL.s)
  Protected L.s = LCase(URL)
  If Left(L, 7) = "http://" Or Left(L, 8) = "https://" : ProcedureReturn 1 : EndIf
  ProcedureReturn 0
EndProcedure

Procedure.s NormalizeURL(URL.s)
  URL = Trim(URL)
  If URL = "" : ProcedureReturn "" : EndIf
  If StartsWithProtocol(URL) = 0
    If Left(LCase(URL), 9) = "localhost" Or Left(URL, 9) = "127.0.0.1" Or Left(URL, 5) = "[::1]"
      URL = "http://" + URL
    Else
      URL = "https://" + URL
    EndIf
  EndIf
  If IsAllowedScheme(URL) = 0 : ProcedureReturn "" : EndIf
  ProcedureReturn URL
EndProcedure

Procedure.i BrowserIsExplicit()
  If BrowserPath <> "" And LCase(BrowserPath) <> "explorer.exe" And FileSize(BrowserPath) >= 0
    ProcedureReturn 1
  EndIf
  ProcedureReturn 0
EndProcedure

Procedure SendKeyInput(VKey.w, Flags.l)
  Protected Input.INPUT
  Input\type = #INPUT_KEYBOARD
  Input\ki\wVk = VKey
  Input\ki\wScan = 0
  Input\ki\dwFlags = Flags
  Input\ki\time = 0
  Input\ki\dwExtraInfo = 0
  SendInput_(1, @Input, SizeOf(INPUT))
EndProcedure

Procedure.s ReadRegString(hKeyRoot, KeyPath.s, ValueName.s)
  Protected hKey.i, Type.i, BufferSize.i, Result.s = ""
  Protected *Buffer, QueryResult.i
  
  If RegOpenKeyEx_(hKeyRoot, KeyPath, 0, #KEY_READ, @hKey) = #ERROR_SUCCESS
    BufferSize = 0
    QueryResult = RegQueryValueEx_(hKey, ValueName, 0, @Type, 0, @BufferSize)
    If (QueryResult = #ERROR_SUCCESS Or QueryResult = 234) And BufferSize > 0
      *Buffer = AllocateMemory(BufferSize + SizeOf(Character))
      If *Buffer
        If RegQueryValueEx_(hKey, ValueName, 0, @Type, *Buffer, @BufferSize) = #ERROR_SUCCESS
          If Type = #REG_SZ Or Type = #REG_EXPAND_SZ
            Result = PeekS(*Buffer, BufferSize / SizeOf(Character))
          EndIf
        EndIf
        FreeMemory(*Buffer)
      EndIf
    EndIf
    RegCloseKey_(hKey)
  EndIf
  ProcedureReturn Result
EndProcedure

Procedure ScanBrowserRegistryKey(hKeyRoot.i)
  Protected hKey.i, Index.i = 0
  Protected KeyName.s = Space(256), KeyNameSize.i
  Protected SubKeyName.s, BName.s, BPath.s
  
  If RegOpenKeyEx_(hKeyRoot, "SOFTWARE\Clients\StartMenuInternet", 0, #KEY_READ, @hKey) = #ERROR_SUCCESS
    Repeat
      KeyNameSize = 256
      If RegEnumKeyEx_(hKey, Index, @KeyName, @KeyNameSize, 0, 0, 0, 0) = #ERROR_SUCCESS
        SubKeyName = "SOFTWARE\Clients\StartMenuInternet\" + Left(KeyName, KeyNameSize)
        BName = ReadRegString(hKeyRoot, SubKeyName, "")
        If BName = "" : BName = Left(KeyName, KeyNameSize) : EndIf
        BPath = ReadRegString(hKeyRoot, SubKeyName + "\shell\open\command", "")
        If FindString(LCase(BPath), ".exe")
          BPath = Left(BPath, FindString(LCase(BPath), ".exe") + 3)
          BPath = RemoveString(BPath, #DQUOTE$)
        EndIf
        If BName <> "" And BPath <> ""
          AddElement(InstalledBrowsers())
          InstalledBrowsers()\Name = BName
          InstalledBrowsers()\Path = BPath
        EndIf
        Index + 1
      Else
        Break
      EndIf
    ForEver
    RegCloseKey_(hKey)
  EndIf
EndProcedure

Procedure GetInstalledBrowsers()
  ClearList(InstalledBrowsers())
  ScanBrowserRegistryKey(#HKEY_LOCAL_MACHINE)
  ScanBrowserRegistryKey(#HKEY_CURRENT_USER)
  If ListSize(InstalledBrowsers()) = 0
    AddElement(InstalledBrowsers())
    InstalledBrowsers()\Name = "System Default"
    InstalledBrowsers()\Path = "explorer.exe" 
  EndIf
EndProcedure

Procedure GetAvailableLanguages()
  Protected Directory.s = GetPathPart(ProgramFilename())
  Protected DirID.i, FileName.s, LangCode.s
  ClearList(AvailableLanguages())
  DirID = ExamineDirectory(#PB_Any, Directory, "*.lng")
  If DirID
    While NextDirectoryEntry(DirID)
      If DirectoryEntryType(DirID) = #PB_DirectoryEntry_File
        FileName = DirectoryEntryName(DirID)
        LangCode = UCase(Left(FileName, Len(FileName) - 4))
        If OpenPreferences(Directory + FileName, #PB_UTF8)
          PreferenceGroup("Language")
          AddElement(AvailableLanguages())
          AvailableLanguages()\Code = LangCode
          AvailableLanguages()\Name = ReadPreferenceString("LanguageName", LangCode)
          ClosePreferences()
        EndIf
      EndIf
    Wend
    FinishDirectory(DirID)
  EndIf
  If ListSize(AvailableLanguages()) = 0
    AddElement(AvailableLanguages())
    AvailableLanguages()\Code = "DA"
    AvailableLanguages()\Name = "Dansk"
  EndIf
EndProcedure

Procedure AddAIService(Name.s, URL.s, IsCustom.i)
  Name = Trim(Name)
  URL = NormalizeURL(URL)
  If Name = "" Or URL = "" : ProcedureReturn : EndIf
  ForEach AIServices()
    If LCase(AIServices()\Name) = LCase(Name)
      AIServices()\URL = URL
      AIServices()\IsCustom = IsCustom
      ProcedureReturn
    EndIf
  Next
  AddElement(AIServices())
  AIServices()\Name = Name
  AIServices()\URL = URL
  AIServices()\IsCustom = IsCustom
EndProcedure

Procedure.s GetAIURLByName(Name.s)
  ForEach AIServices()
    If LCase(AIServices()\Name) = LCase(Name)
      ProcedureReturn AIServices()\URL
    EndIf
  Next
  ProcedureReturn "https://gemini.google.com"
EndProcedure

Procedure LoadAIServices()
  Protected Count.i, I.i, Name.s, URL.s
  ClearList(AIServices())
  AddAIService("Gemini", "https://gemini.google.com", 0)
  AddAIService("Kimi", "https://www.kimi.com", 0)
  AddAIService("ChatGPT", "https://chatgpt.com", 0)
  AddAIService("Claude", "https://claude.ai", 0)
  AddAIService("DeepSeek", "https://chat.deepseek.com", 0)
  AddAIService("Perplexity", "https://www.perplexity.ai", 0)
  AddAIService("Copilot", "https://copilot.microsoft.com", 0)
  
  If OpenPreferences(IniFile, #PB_UTF8)
    PreferenceGroup("CustomAI")
    Count = ReadPreferenceInteger("Count", 0)
    For I = 1 To Count
      Name = ReadPreferenceString(Str(I) + "Name", "")
      URL = ReadPreferenceString(Str(I) + "URL", "")
      AddAIService(Name, URL, 1)
    Next
    ClosePreferences()
  EndIf
EndProcedure

Procedure SaveCustomAIServices()
  Protected Count.i = 0, I.i = 0
  If OpenPreferences(IniFile, #PB_UTF8) Or CreatePreferences(IniFile, #PB_UTF8)
    PreferenceGroup("CustomAI")
    ForEach AIServices()
      If AIServices()\IsCustom : Count + 1 : EndIf
    Next
    WritePreferenceInteger("Count", Count)
    ForEach AIServices()
      If AIServices()\IsCustom
        I + 1
        WritePreferenceString(Str(I) + "Name", AIServices()\Name)
        WritePreferenceString(Str(I) + "URL", AIServices()\URL)
      EndIf
    Next
    ClosePreferences()
  EndIf
EndProcedure

Procedure UpdateTargetURL()
  TargetURL = GetAIURLByName(SelectedAI)
EndProcedure

Procedure.s FormatKeyCombo(vkCode.w, Modifiers.i)
  Protected Text.s = ""
  If Modifiers & #HOTKEY_MOD_CTRL  : Text + "Ctrl + "  : EndIf
  If Modifiers & #HOTKEY_MOD_ALT   : Text + "Alt + "   : EndIf
  If Modifiers & #HOTKEY_MOD_SHIFT : Text + "Shift + " : EndIf
  If Modifiers & #HOTKEY_MOD_WIN   : Text + "Win + "   : EndIf
  
  Select vkCode
    Case $86 : Text + "Copilot (Standard)"
    Case #VK_SPACE    : Text + "Space"
    Case #VK_RETURN   : Text + "Enter"
    Case #VK_TAB      : Text + "Tab"
    Case #VK_ESCAPE   : Text + "Esc"
    Case #VK_BACK     : Text + "Backspace"
    Case #VK_INSERT   : Text + "Insert"
    Case #VK_DELETE   : Text + "Delete"
    Case #VK_HOME     : Text + "Home"
    Case #VK_END      : Text + "End"
    Case #VK_PRIOR    : Text + "Page Up"
    Case #VK_NEXT     : Text + "Page Down"
    Case #VK_F1 To #VK_F24
      Text + "F" + Str(vkCode - #VK_F1 + 1)
    Default
      Protected ScanCode.l = MapVirtualKey_(vkCode, 0)
      Protected KeyBuf.s = Space(64)
      If GetKeyNameText_(ScanCode << 16, @KeyBuf, 64) > 0
        Text + Trim(KeyBuf)
      Else
        If (vkCode >= '0' And vkCode <= '9') Or (vkCode >= 'A' And vkCode <= 'Z')
          Text + Chr(vkCode)
        Else
          Text + "Tastekode $" + Hex(vkCode)
        EndIf
      EndIf
  EndSelect
  ProcedureReturn Text
EndProcedure

Procedure.s LaunchModeName(Mode.i)
  Select Mode
    Case 0 : ProcedureReturn Txt_LaunchApp
    Case 1 : ProcedureReturn Txt_LaunchTab
    Case 2 : ProcedureReturn Txt_LaunchWindow
    Case 3 : ProcedureReturn Txt_LaunchDefault
  EndSelect
  ProcedureReturn Txt_LaunchApp
EndProcedure

Procedure.i GetGadgetTextWidth(GadgetID.i, Text.s)
  Protected hDC.i, Size.SIZE, Font.i, OldFont.i, Width.i = 85
  
  If IsGadget(GadgetID)
    hDC = GetDC_(GadgetID(GadgetID))
    If hDC
      Font = SendMessage_(GadgetID(GadgetID), #WM_GETFONT, 0, 0)
      If Font : OldFont = SelectObject_(hDC, Font) : EndIf
      
      If GetTextExtentPoint32_(hDC, Text, Len(Text), @Size)
        Width = Size\cx + 20 ; +20 px padding til knappens ramme
      EndIf
      
      If OldFont : SelectObject_(hDC, OldFont) : EndIf
      ReleaseDC_(GadgetID(GadgetID), hDC)
    EndIf
  EndIf
  
  ProcedureReturn Width
EndProcedure

; ----------------------------------------------------------------------------
; CORE LOGIC: WINDOW & BROWSER LAUNCHERS
; ----------------------------------------------------------------------------
Procedure PopulateAICombo(ComboGadgetID.i)
  Protected i.i
  ClearGadgetItems(ComboGadgetID)
  ForEach AIServices()
    AddGadgetItem(ComboGadgetID, -1, AIServices()\Name)
  Next
  For i = 0 To CountGadgetItems(ComboGadgetID) - 1
    If LCase(GetGadgetItemText(ComboGadgetID, i)) = LCase(SelectedAI)
      SetGadgetState(ComboGadgetID, i)
      Break
    EndIf
  Next
EndProcedure

Procedure OpenEmbeddedAI(URL.s)
  URL = NormalizeURL(URL)
  If URL = "" : ProcedureReturn : EndIf
  
  If IsWindow(#AIWin)
    SetWindowState(#AIWin, #PB_Window_Normal)
    StickyWindow(#AIWin, 1)
    SetActiveWindow(#AIWin)
    StickyWindow(#AIWin, 0)
    SetGadgetText(#AIGadget, URL)
    PopulateAICombo(#AICombo)
    ProcedureReturn
  EndIf
  
  If OpenWindow(#AIWin, #PB_Ignore, #PB_Ignore, 1024, 768, "AI Copilot View", #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_MaximizeGadget)
    StickyWindow(#AIWin, 1)
    SetActiveWindow(#AIWin)
    StickyWindow(#AIWin, 0)
    ComboBoxGadget(#AICombo, 10, 5, 250, 25)
    PopulateAICombo(#AICombo)
    If WebViewGadget(#AIGadget, 0, 35, 1024, 768 - 35)
      SetGadgetText(#AIGadget, URL) 
      ResizeGadget(#AIGadget, 0, 35, WindowWidth(#AIWin), WindowHeight(#AIWin) - 35)
    EndIf
  EndIf
EndProcedure

Procedure LaunchTarget(URL.s, UseLaunchMode.i)
  If UseEmbeddedBrowser = 1
    OpenEmbeddedAI(URL)
    ProcedureReturn
  EndIf

  URL = NormalizeURL(URL)
  If URL = "" : ProcedureReturn : EndIf
  
  Select UseLaunchMode
    Case 0 
      If BrowserIsExplicit()
        RunProgram(BrowserPath, "--app=" + Chr(34) + URL + Chr(34), "")
      Else
        RunProgram(URL, "", "")
      EndIf
    Case 1 
      If BrowserIsExplicit()
        RunProgram(BrowserPath, Chr(34) + URL + Chr(34), "")
      Else
        RunProgram(URL, "", "")
      EndIf
    Case 2 
      If BrowserIsExplicit()
        RunProgram(BrowserPath, "--new-window " + Chr(34) + URL + Chr(34), "")
      Else
        RunProgram(URL, "", "")
      EndIf
    Case 3 
      RunProgram(URL, "", "")
    Default
      RunProgram(URL, "", "")
  EndSelect
EndProcedure

; ----------------------------------------------------------------------------
; SETTINGS & PROFILE MANAGEMENT
; ----------------------------------------------------------------------------
Procedure.i SetAutoStartRegistry(Enable.i)
  Protected hKey.i, Result.i
  Protected KeyPath.s = "Software\Microsoft\Windows\CurrentVersion\Run"
  Protected ValueName.s = "AICopilotMapper"
  Protected Path.s = Chr(34) + ProgramFilename() + Chr(34)
  Protected DataSize.i = StringByteLength(Path) + SizeOf(Character)
  Protected AccessMask.i = $0002 
  
  Result = RegOpenKeyEx_(#HKEY_CURRENT_USER, KeyPath, 0, AccessMask, @hKey)
  If Result = #ERROR_SUCCESS
    If Enable
      Result = RegSetValueEx_(hKey, ValueName, 0, #REG_SZ, @Path, DataSize)
    Else
      Result = RegDeleteValue_(hKey, ValueName)
      If Result <> #ERROR_SUCCESS
        If Result = 2 : Result = #ERROR_SUCCESS : EndIf
      EndIf
    EndIf
    RegCloseKey_(hKey)
  EndIf
  
  If Result <> #ERROR_SUCCESS
    MessageRequester(Txt_RegErrorTitle, Txt_RegErrorMsg + Chr(10) + "Fejlkode: " + Str(Result), #PB_MessageRequester_Warning)
    ProcedureReturn 0
  EndIf
  ProcedureReturn 1
EndProcedure

Procedure SaveSettings()
  If OpenPreferences(IniFile, #PB_UTF8) Or CreatePreferences(IniFile, #PB_UTF8)
    PreferenceGroup("Settings")
    WritePreferenceString("Browser", BrowserPath)
    WritePreferenceInteger("AutoStart", AutoStart)
    WritePreferenceString("Language", Language)
    WritePreferenceString("AI", SelectedAI)
    WritePreferenceInteger("ButtonMode", ButtonMode)
    WritePreferenceInteger("LaunchMode", LaunchMode)
    WritePreferenceInteger("UseEmbeddedBrowser", UseEmbeddedBrowser)
    WritePreferenceInteger("CustomKeyVK", TriggerVK)
    WritePreferenceInteger("CustomKeyModifiers", TriggerModifiers)
    WritePreferenceString("CustomKeyName", TriggerKeyName)
    ClosePreferences()
  EndIf
EndProcedure

Procedure LoadSettings()
  If OpenPreferences(IniFile, #PB_UTF8)
    PreferenceGroup("Settings")
    BrowserPath = ReadPreferenceString("Browser", "")
    AutoStart = ReadPreferenceInteger("AutoStart", 0)
    Language = ReadPreferenceString("Language", "DA")
    SelectedAI = ReadPreferenceString("AI", "Gemini")
    ButtonMode = ReadPreferenceInteger("ButtonMode", 0)
    LaunchMode = ReadPreferenceInteger("LaunchMode", 0)
    UseEmbeddedBrowser = ReadPreferenceInteger("UseEmbeddedBrowser", 1)
    TriggerVK = ReadPreferenceInteger("CustomKeyVK", $86)
    TriggerModifiers = ReadPreferenceInteger("CustomKeyModifiers", 0)
    TriggerKeyName = ReadPreferenceString("CustomKeyName", "Copilot-tast")
    ClosePreferences()
  EndIf
  
  If BrowserPath = "" Or (LCase(BrowserPath) <> "explorer.exe" And FileSize(BrowserPath) < 0)
    If FirstElement(InstalledBrowsers())
      BrowserPath = InstalledBrowsers()\Path
    Else
      BrowserPath = "explorer.exe"
    EndIf
  EndIf
  
  If ButtonMode < 0 Or ButtonMode > 2 : ButtonMode = 0 : EndIf
  If LaunchMode < 0 Or LaunchMode > 3 : LaunchMode = 0 : EndIf
  If GetAIURLByName(SelectedAI) = "https://gemini.google.com" And LCase(SelectedAI) <> "gemini"
    SelectedAI = "Gemini"
  EndIf
  UpdateTargetURL() 
EndProcedure

Procedure CreateProfileTemplate(Overwrite.i)
  Protected File.i
  If FileSize(ProfileFile) >= 0 And Overwrite = 0 : ProcedureReturn : EndIf
  
  File = CreateFile(#PB_Any, ProfileFile, #PB_UTF8)
  If File
    WriteStringN(File, "; AI Copilot Mapper - profiler pr. app")
    WriteStringN(File, "; Sæt Count til antal aktive profiler, og udfyld felterne nedenfor.")
    WriteStringN(File, "")
    WriteStringN(File, "[Profiles]")
    WriteStringN(File, "Count=0")
    CloseFile(File)
  EndIf
EndProcedure

Procedure LoadAppProfiles()
  Protected Count.i, I.i
  ClearList(AppProfiles())
  CreateProfileTemplate(0)
  
  If OpenPreferences(ProfileFile, #PB_UTF8)
    PreferenceGroup("Profiles")
    Count = ReadPreferenceInteger("Count", 0)
    For I = 1 To Count
      If ReadPreferenceString(Str(I) + "Process", "") <> ""
        AddElement(AppProfiles())
        AppProfiles()\Process = LCase(Trim(ReadPreferenceString(Str(I) + "Process", "")))
        AppProfiles()\Mode = ReadPreferenceInteger(Str(I) + "Mode", -1)
        AppProfiles()\AIName = Trim(ReadPreferenceString(Str(I) + "AIName", ""))
        AppProfiles()\AIURL = NormalizeURL(ReadPreferenceString(Str(I) + "AIURL", ""))
        AppProfiles()\LaunchMode = ReadPreferenceInteger(Str(I) + "LaunchMode", -1)
        AppProfiles()\Paused = ReadPreferenceInteger(Str(I) + "Paused", -1)
      EndIf
    Next
    ClosePreferences()
  EndIf
EndProcedure

Procedure OpenProfileFile()
  CreateProfileTemplate(0)
  RunProgram("notepad.exe", Chr(34) + ProfileFile + Chr(34), "")
EndProcedure

Procedure.s GetActiveProcessName()
  Protected hWnd.i, PID.i, hProcess.i
  Protected Buffer.s = Space(1024), Size.i = 1024
  Protected Result.s = ""
  
  hWnd = GetForegroundWindow_()
  If hWnd = 0 : ProcedureReturn "" : EndIf
  GetWindowThreadProcessId_(hWnd, @PID)
  If PID = 0 : ProcedureReturn "" : EndIf
  
  hProcess = OpenProcess_($1000, 0, PID)
  If hProcess
    If QueryFullProcessImageNameW(hProcess, 0, @Buffer, @Size)
      Result = LCase(GetFilePart(Left(Buffer, Size)))
    EndIf
    CloseHandle_(hProcess)
  EndIf
  ProcedureReturn Result
EndProcedure

Procedure UpdateActiveProfileCache()
  Protected Proc.s = GetActiveProcessName()
  CachedProfileActive = 0
  CachedProfileMode = -1
  CachedProfileLaunchMode = -1
  CachedProfileAIURL = ""
  CachedProfilePaused = -1
  
  If Proc = "" : ProcedureReturn : EndIf
  
  ForEach AppProfiles()
    If LCase(AppProfiles()\Process) = Proc
      CachedProfileActive = 1
      CachedProfileMode = AppProfiles()\Mode
      CachedProfileLaunchMode = AppProfiles()\LaunchMode
      CachedProfilePaused = AppProfiles()\Paused
      If AppProfiles()\AIURL <> ""
        CachedProfileAIURL = AppProfiles()\AIURL
      ElseIf AppProfiles()\AIName <> ""
        CachedProfileAIURL = GetAIURLByName(AppProfiles()\AIName)
      EndIf
      Break
    EndIf
  Next
EndProcedure

; ----------------------------------------------------------------------------
; LOCALIZATION & SYSTEM TRAY
; ----------------------------------------------------------------------------
Procedure UpdateLanguageStrings()
  Protected AppName.s = "AI Copilot Mapper"
  Protected VerPrefix.s = " v" + #AppVersion + Chr(10)
  Protected LngFile.s = GetPathPart(ProgramFilename()) + Language + ".lng"
  
  ; Fallbacks (Dansk)
  Txt_ModeAI = "AI-genvej"
  Txt_ModeCTRL = "Højre CTRL"
  Txt_ModeALT = "Højre ALT"
  Txt_MenuPause = "Pause mapping"
  Txt_MenuAbout = "Om programmet"
  Txt_MenuExit = "Afslut"
  Txt_MenuSettings = "Indstillinger..."
  Txt_MenuOpenAI = "Åbn AI View"
  Txt_LaunchApp = "App-vindue"
  Txt_LaunchTab = "Normal fane"
  Txt_LaunchWindow = "Nyt vindue"
  Txt_LaunchDefault = "Systemstandard"
  Txt_MenuLaunchMode = "Åbningsmetode"
  Txt_AboutTitle = "Om " + AppName
  Txt_AboutText = AppName + VerPrefix + "Omkod Copilot-tasten eller din egen brugerdefinerede genvej til en AI eller modtast."
  Txt_MsgBoxRunning = "Programmet kører allerede."
  Txt_CustomAINamePrompt = "Navn på AI-tjenesten:" + Chr(10) + "Eksempel: Open WebUI"
  Txt_CustomAIURLPrompt = "URL til AI-tjenesten:" + Chr(10) + "Eksempel: http://localhost:3000"
  Txt_CustomAINotCustomTitle = "Custom AI"
  Txt_CustomAINotCustomMsg = "Den valgte AI er ikke en custom AI og kan derfor ikke fjernes her."
  Txt_RegErrorTitle = "Rettighedsfejl"
  Txt_RegErrorMsg = "Windows nægtede adgang til Autostart."
  Txt_ProfileReloadedTitle = "Profiler"
  Txt_ProfileReloadedMsg = "Profiler er genindlæst."
  
  Txt_MenuHotkey = "Genvejstast"
  Txt_HotkeyConfigure = "Optag ny genvej..."
  Txt_HotkeyReset = "Nulstil til Copilot-tast"
  Txt_HotkeyCurrent = "Aktiv genvej: "
  Txt_HotkeyPrompt = "Tryk på den ønskede tastekombination nu..." + Chr(10) + "(F.eks. Ctrl+Alt+Mellemrum, F12, Win+Shift+A)"
  Txt_HotkeyWaiting = "Venter på tastetryk..."
  Txt_HotkeyCancel = "Annuller"
  Txt_SettingsTitle = "AI Copilot Mapper - Indstillinger"
  Txt_FrameHotkey = "Genvejstast og Funktion"
  Txt_BtnRecord = "Optag..."
  Txt_BtnReset = "Nulstil"
  Txt_LabelButtonAction = "Knaphandling:"
  Txt_FrameAI = "AI Tjeneste"
  Txt_BtnAddCustom = "Tilføj Custom"
  Txt_BtnRemoveSelected = "Fjern Valgt"
  Txt_FrameBrowser = "Browser og Visning"
  Txt_MenuEmbedded = "Brug Indbygget WebView2 (Hurtig)"
  Txt_LabelExternalBrowser = "Ekstern browser:"
  Txt_FrameSystem = "System og Profiler"
  Txt_MenuAutoStart = "Start med Windows"
  Txt_MenuLanguage = "Sprog"
  Txt_BtnOpenProfiles = "Åbn App-profiler (.ini)"
  Txt_BtnReloadProfiles = "Genindlæs App-profiler"
  Txt_BtnClose = "Luk"
  
  ; Indlæs fra sprogfil hvis tilgængelig
  If FileSize(LngFile) > 0
    If OpenPreferences(LngFile, #PB_UTF8)
      PreferenceGroup("Language")
      Txt_ModeAI = ReadPreferenceString("ModeAI", Txt_ModeAI)
      Txt_ModeCTRL = ReadPreferenceString("ModeCTRL", Txt_ModeCTRL)
      Txt_ModeALT = ReadPreferenceString("ModeALT", Txt_ModeALT)
      Txt_MenuPause = ReadPreferenceString("MenuPause", Txt_MenuPause)
      Txt_MenuAbout = ReadPreferenceString("MenuAbout", Txt_MenuAbout)
      Txt_MenuExit = ReadPreferenceString("MenuExit", Txt_MenuExit)
      Txt_MenuSettings = ReadPreferenceString("MenuSettings", Txt_MenuSettings)
      Txt_MenuOpenAI = ReadPreferenceString("MenuOpenAI", Txt_MenuOpenAI)
      Txt_LaunchApp = ReadPreferenceString("LaunchApp", Txt_LaunchApp)
      Txt_LaunchTab = ReadPreferenceString("LaunchTab", Txt_LaunchTab)
      Txt_LaunchWindow = ReadPreferenceString("LaunchWindow", Txt_LaunchWindow)
      Txt_LaunchDefault = ReadPreferenceString("LaunchDefault", Txt_LaunchDefault)
      Txt_MenuLaunchMode = ReadPreferenceString("MenuLaunchMode", Txt_MenuLaunchMode)
      Txt_AboutTitle = ReadPreferenceString("AboutTitle", Txt_AboutTitle)
      Txt_AboutText = AppName + VerPrefix + ReadPreferenceString("AboutText", Txt_AboutText)
      Txt_MsgBoxRunning = ReadPreferenceString("MsgBoxRunning", Txt_MsgBoxRunning)
      Txt_CustomAINamePrompt = ReplaceString(ReadPreferenceString("CustomAINamePrompt", Txt_CustomAINamePrompt), "\n", Chr(10))
      Txt_CustomAIURLPrompt = ReplaceString(ReadPreferenceString("CustomAIURLPrompt", Txt_CustomAIURLPrompt), "\n", Chr(10))
      Txt_CustomAINotCustomTitle = ReadPreferenceString("CustomAINotCustomTitle", Txt_CustomAINotCustomTitle)
      Txt_CustomAINotCustomMsg = ReadPreferenceString("CustomAINotCustomMsg", Txt_CustomAINotCustomMsg)
      Txt_RegErrorTitle = ReadPreferenceString("RegErrorTitle", Txt_RegErrorTitle)
      Txt_RegErrorMsg = ReadPreferenceString("RegErrorMsg", Txt_RegErrorMsg)
      Txt_ProfileReloadedTitle = ReadPreferenceString("ProfileReloadedTitle", Txt_ProfileReloadedTitle)
      Txt_ProfileReloadedMsg = ReadPreferenceString("ProfileReloadedMsg", Txt_ProfileReloadedMsg)
      Txt_MenuHotkey = ReadPreferenceString("MenuHotkey", Txt_MenuHotkey)
      Txt_HotkeyConfigure = ReadPreferenceString("HotkeyConfigure", Txt_HotkeyConfigure)
      Txt_HotkeyReset = ReadPreferenceString("HotkeyReset", Txt_HotkeyReset)
      Txt_HotkeyCurrent = ReadPreferenceString("HotkeyCurrent", Txt_HotkeyCurrent)
      Txt_HotkeyPrompt = ReplaceString(ReadPreferenceString("HotkeyPrompt", Txt_HotkeyPrompt), "\n", Chr(10))
      Txt_HotkeyWaiting = ReadPreferenceString("HotkeyWaiting", Txt_HotkeyWaiting)
      Txt_HotkeyCancel = ReadPreferenceString("HotkeyCancel", Txt_HotkeyCancel)
      Txt_SettingsTitle = ReadPreferenceString("SettingsTitle", Txt_SettingsTitle)
      Txt_FrameHotkey = ReadPreferenceString("FrameHotkey", Txt_FrameHotkey)
      Txt_BtnRecord = ReadPreferenceString("BtnRecord", Txt_BtnRecord)
      Txt_BtnReset = ReadPreferenceString("BtnReset", Txt_BtnReset)
      Txt_LabelButtonAction = ReadPreferenceString("LabelButtonAction", Txt_LabelButtonAction)
      Txt_FrameAI = ReadPreferenceString("FrameAI", Txt_FrameAI)
      Txt_BtnAddCustom = ReadPreferenceString("BtnAddCustom", Txt_BtnAddCustom)
      Txt_BtnRemoveSelected = ReadPreferenceString("BtnRemoveSelected", Txt_BtnRemoveSelected)
      Txt_FrameBrowser = ReadPreferenceString("FrameBrowser", Txt_FrameBrowser)
      Txt_MenuEmbedded = ReadPreferenceString("MenuEmbedded", Txt_MenuEmbedded)
      Txt_LabelExternalBrowser = ReadPreferenceString("LabelExternalBrowser", Txt_LabelExternalBrowser)
      Txt_FrameSystem = ReadPreferenceString("FrameSystem", Txt_FrameSystem)
      Txt_MenuAutoStart = ReadPreferenceString("MenuAutoStart", Txt_MenuAutoStart)
      Txt_MenuLanguage = ReadPreferenceString("MenuLanguage", Txt_MenuLanguage)
      Txt_BtnOpenProfiles = ReadPreferenceString("BtnOpenProfiles", Txt_BtnOpenProfiles)
      Txt_BtnReloadProfiles = ReadPreferenceString("BtnReloadProfiles", Txt_BtnReloadProfiles)
      Txt_BtnClose = ReadPreferenceString("BtnClose", Txt_BtnClose)
      ClosePreferences()
    EndIf
  EndIf
  
  Txt_MsgBoxTitle = AppName
  Txt_TrayTooltip = AppName
EndProcedure

Procedure UpdateTrayTooltip()
  Protected Tip.s
  Tip = "AI Copilot Mapper v" + #AppVersion + Chr(10)
  If MappingPaused
    Tip + "Status: Pauset" + Chr(10)
  EndIf
  Tip + Txt_HotkeyCurrent + TriggerKeyName + Chr(10)
  Tip + "AI: " + SelectedAI + Chr(10)
  If UseEmbeddedBrowser
    Tip + "Visning: WebView2"
  Else
    Tip + "Visning: Ekstern (" + LaunchModeName(LaunchMode) + ")"
  EndIf
  SysTrayIconToolTip(#TrayIcon, Tip)
EndProcedure

Procedure RebuildMenu()
  If IsMenu(#TrayMenu)
    FreeMenu(#TrayMenu)
  EndIf
  
  If CreatePopupMenu(#TrayMenu)
    MenuItem(#Menu_Tray_OpenAI, Txt_MenuOpenAI)
    MenuItem(#Menu_Tray_Pause, Txt_MenuPause)
    MenuBar()
    MenuItem(#Menu_Tray_Settings, Txt_MenuSettings)
    MenuBar()
    MenuItem(#Menu_Tray_About, Txt_MenuAbout)
    MenuItem(#Menu_Tray_Exit, Txt_MenuExit)
    
    SetMenuItemState(#TrayMenu, #Menu_Tray_Pause, MappingPaused)
  EndIf
  
  UpdateTrayTooltip()
EndProcedure

; ----------------------------------------------------------------------------
; DIALOG: INDSTILLINGER (DEDIKERET VINDUE)
; ----------------------------------------------------------------------------
Procedure UpdateSettingsUI()
  If Not IsWindow(#SettingsWin) : ProcedureReturn : EndIf
  
  ; Mål dynamisk bredde til knapperne i sektionen 'AI Tjeneste'
  Protected BtnAddW.i = GetGadgetTextWidth(#Set_BtnAddAI, Txt_BtnAddCustom)
  Protected BtnDelW.i = GetGadgetTextWidth(#Set_BtnDelAI, Txt_BtnRemoveSelected)
  If BtnAddW < 90 : BtnAddW = 90 : EndIf
  If BtnDelW < 90 : BtnDelW = 90 : EndIf
  
  ; Mål knapperne i øverste sektion (Optag/Nulstil)
  Protected BtnRecW.i = GetGadgetTextWidth(#Set_BtnRecordKey, Txt_BtnRecord)
  Protected BtnRstW.i = GetGadgetTextWidth(#Set_BtnResetKey, Txt_BtnReset)
  If BtnRecW < 85 : BtnRecW = 85 : EndIf
  If BtnRstW < 85 : BtnRstW = 85 : EndIf

  ; Beregn påkrævet totalbredde for vinduet
  ; Venstre margen (15) + Dropdown (min 200) + Spacing (10) + Knap1 + Spacing (10) + Knap2 + Højre margen (15)
  Protected RequiredContentW.i = 200 + 10 + BtnAddW + 10 + BtnDelW
  Protected WinW.i = RequiredContentW + 30
  If WinW < 520 : WinW = 520 : EndIf ; Minimumsbredde af hensyn til bunden
  
  Protected FrameW.i = WinW - 30
  Protected RightEdge.i = 15 + FrameW
  
  ; Skaler selve vinduet
  ResizeWindow(#SettingsWin, #PB_Ignore, #PB_Ignore, WinW, #PB_Ignore)
  SetWindowTitle(#SettingsWin, Txt_SettingsTitle)
  
  ; 1. Genvej & Tastfunktion
  ResizeGadget(#Set_FrameKey, 15, 10, FrameW, 95)
  SetGadgetText(#Set_FrameKey, Txt_FrameHotkey)
  SetGadgetText(#Set_KeyLabel, Txt_HotkeyCurrent + TriggerKeyName)
  ResizeGadget(#Set_BtnResetKey, RightEdge - 15 - BtnRstW, 28, BtnRstW, 25)
  SetGadgetText(#Set_BtnResetKey, Txt_BtnReset)
  ResizeGadget(#Set_BtnRecordKey, RightEdge - 25 - BtnRstW - BtnRecW, 28, BtnRecW, 25)
  SetGadgetText(#Set_BtnRecordKey, Txt_BtnRecord)
  ResizeGadget(#Set_KeyLabel, 30, 32, RightEdge - 35 - BtnRstW - BtnRecW - 30, 20)
  
  SetGadgetText(#Set_LabelBtnAction, Txt_LabelButtonAction)
  ResizeGadget(#Set_ComboMode, 150, 65, FrameW - 145, 25)
  ClearGadgetItems(#Set_ComboMode)
  AddGadgetItem(#Set_ComboMode, -1, Txt_ModeAI)
  AddGadgetItem(#Set_ComboMode, -1, Txt_ModeCTRL)
  AddGadgetItem(#Set_ComboMode, -1, Txt_ModeALT)
  SetGadgetState(#Set_ComboMode, ButtonMode)
  
  ; 2. AI Tjeneste (Dynamisk tilpasning af knapper og dropdown)
  ResizeGadget(#Set_FrameAI, 15, 115, FrameW, 75)
  SetGadgetText(#Set_FrameAI, Txt_FrameAI)
  
  Protected DelX.i = RightEdge - 15 - BtnDelW
  Protected AddX.i = DelX - 10 - BtnAddW
  Protected ComboAIW.i = AddX - 10 - 30
  
  ResizeGadget(#Set_ComboAI, 30, 142, ComboAIW, 25)
  PopulateAICombo(#Set_ComboAI)
  
  ResizeGadget(#Set_BtnAddAI, AddX, 142, BtnAddW, 25)
  SetGadgetText(#Set_BtnAddAI, Txt_BtnAddCustom)
  
  ResizeGadget(#Set_BtnDelAI, DelX, 142, BtnDelW, 25)
  SetGadgetText(#Set_BtnDelAI, Txt_BtnRemoveSelected)
  
  ; 3. Browser Integration
  ResizeGadget(#Set_FrameBrowser, 15, 200, FrameW, 115)
  SetGadgetText(#Set_FrameBrowser, Txt_FrameBrowser)
  ResizeGadget(#Set_ChkEmbedded, 30, 222, FrameW - 30, 20)
  SetGadgetText(#Set_ChkEmbedded, Txt_MenuEmbedded)
  SetGadgetState(#Set_ChkEmbedded, UseEmbeddedBrowser)
  
  SetGadgetText(#Set_LabelBrowser, Txt_LabelExternalBrowser)
  ResizeGadget(#Set_ComboBrowser, 150, 248, FrameW - 145, 25)
  
  SetGadgetText(#Set_LabelLaunchMode, Txt_MenuLaunchMode + ":")
  ResizeGadget(#Set_ComboLaunchMode, 150, 278, FrameW - 145, 25)
  
  DisableGadget(#Set_ComboBrowser, UseEmbeddedBrowser)
  DisableGadget(#Set_ComboLaunchMode, UseEmbeddedBrowser)
  
  Protected i.i, bIdx.i = 0
  ClearGadgetItems(#Set_ComboBrowser)
  ForEach InstalledBrowsers()
    AddGadgetItem(#Set_ComboBrowser, -1, InstalledBrowsers()\Name)
    If LCase(BrowserPath) = LCase(InstalledBrowsers()\Path)
      bIdx = ListIndex(InstalledBrowsers())
    EndIf
  Next
  SetGadgetState(#Set_ComboBrowser, bIdx)
  
  ClearGadgetItems(#Set_ComboLaunchMode)
  AddGadgetItem(#Set_ComboLaunchMode, -1, Txt_LaunchApp)
  AddGadgetItem(#Set_ComboLaunchMode, -1, Txt_LaunchTab)
  AddGadgetItem(#Set_ComboLaunchMode, -1, Txt_LaunchWindow)
  AddGadgetItem(#Set_ComboLaunchMode, -1, Txt_LaunchDefault)
  SetGadgetState(#Set_ComboLaunchMode, LaunchMode)
  
  ; 4. System & Profiler
  ResizeGadget(#Set_FrameSystem, 15, 325, FrameW, 105)
  SetGadgetText(#Set_FrameSystem, Txt_FrameSystem)
  SetGadgetText(#Set_ChkAutoStart, Txt_MenuAutoStart)
  SetGadgetState(#Set_ChkAutoStart, AutoStart)
  
  ResizeGadget(#Set_LabelLang, 240, 350, 60, 20)
  SetGadgetText(#Set_LabelLang, Txt_MenuLanguage + ":")
  ResizeGadget(#Set_ComboLang, 305, 346, FrameW - 300, 25)
  
  ClearGadgetItems(#Set_ComboLang)
  Protected lIdx.i = 0
  ForEach AvailableLanguages()
    AddGadgetItem(#Set_ComboLang, -1, AvailableLanguages()\Name)
    If UCase(Language) = UCase(AvailableLanguages()\Code)
      lIdx = ListIndex(AvailableLanguages())
    EndIf
  Next
  SetGadgetState(#Set_ComboLang, lIdx)
  
  Protected HalfBtnW.i = (FrameW - 35) / 2
  ResizeGadget(#Set_BtnOpenProfiles, 30, 385, HalfBtnW, 26)
  SetGadgetText(#Set_BtnOpenProfiles, Txt_BtnOpenProfiles)
  ResizeGadget(#Set_BtnReloadProfiles, 30 + HalfBtnW + 15, 385, HalfBtnW, 26)
  SetGadgetText(#Set_BtnReloadProfiles, Txt_BtnReloadProfiles)
  
  ; Luk-knap centreres
  ResizeGadget(#Set_BtnSaveClose, (WinW / 2) - 60, 440, 120, 30)
  SetGadgetText(#Set_BtnSaveClose, Txt_BtnClose)
EndProcedure

Procedure OpenSettingsWindow()
  If IsWindow(#SettingsWin)
    SetActiveWindow(#SettingsWin)
    ProcedureReturn
  EndIf
  
  If OpenWindow(#SettingsWin, #PB_Ignore, #PB_Ignore, 520, 485, Txt_SettingsTitle, #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
    FrameGadget(#Set_FrameKey, 15, 10, 490, 95, "")
    TextGadget(#Set_KeyLabel, 30, 32, 220, 20, "")
    ButtonGadget(#Set_BtnRecordKey, 310, 28, 85, 25, "")
    ButtonGadget(#Set_BtnResetKey, 405, 28, 85, 25, "")
    
    TextGadget(#Set_LabelBtnAction, 30, 68, 120, 20, "")
    ComboBoxGadget(#Set_ComboMode, 150, 65, 345, 25)
    
    FrameGadget(#Set_FrameAI, 15, 115, 490, 75, "")
    ComboBoxGadget(#Set_ComboAI, 30, 142, 230, 25)
    ButtonGadget(#Set_BtnAddAI, 270, 142, 105, 25, "")
    ButtonGadget(#Set_BtnDelAI, 385, 142, 105, 25, "")
    
    FrameGadget(#Set_FrameBrowser, 15, 200, 490, 115, "")
    CheckBoxGadget(#Set_ChkEmbedded, 30, 222, 450, 20, "")
    
    TextGadget(#Set_LabelBrowser, 30, 252, 110, 20, "")
    ComboBoxGadget(#Set_ComboBrowser, 150, 248, 345, 25)
    
    TextGadget(#Set_LabelLaunchMode, 30, 282, 110, 20, "")
    ComboBoxGadget(#Set_ComboLaunchMode, 150, 278, 345, 25)
    
    FrameGadget(#Set_FrameSystem, 15, 325, 490, 105, "")
    CheckBoxGadget(#Set_ChkAutoStart, 30, 348, 190, 20, "")
    
    TextGadget(#Set_LabelLang, 240, 350, 60, 20, "")
    ComboBoxGadget(#Set_ComboLang, 305, 346, 190, 25)
    
    ButtonGadget(#Set_BtnOpenProfiles, 30, 385, 220, 26, "")
    ButtonGadget(#Set_BtnReloadProfiles, 265, 385, 220, 26, "")
    
    ButtonGadget(#Set_BtnSaveClose, 200, 440, 120, 30, "")
    
    UpdateSettingsUI()
  EndIf
EndProcedure

Procedure OpenHotkeyRecorder()
  If IsWindow(#HotkeyWin)
    SetActiveWindow(#HotkeyWin)
    ProcedureReturn
  EndIf
  
  RecordDlgOpen = 1
  RecordedVK = 0
  RecordedModifiers = 0
  RecordedKeyName = ""
  
  If OpenWindow(#HotkeyWin, #PB_Ignore, #PB_Ignore, 360, 140, Txt_MenuHotkey, #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
    StickyWindow(#HotkeyWin, 1)
    TextGadget(#Hotkey_TextPrompt, 20, 15, 320, 40, Txt_HotkeyPrompt)
    TextGadget(#Hotkey_TextStatus, 20, 65, 320, 25, Txt_HotkeyWaiting, #PB_Text_Center)
    ButtonGadget(#Hotkey_BtnCancel, 130, 95, 100, 30, Txt_HotkeyCancel)
  EndIf
EndProcedure

Procedure AddOrEditCustomAI()
  Protected Name.s, URL.s
  Name = InputRequester("Custom AI", Txt_CustomAINamePrompt, "")
  If Trim(Name) = "" : ProcedureReturn : EndIf
  URL = InputRequester("Custom AI", Txt_CustomAIURLPrompt, "http://localhost:3000")
  URL = NormalizeURL(URL)
  If Trim(URL) = "" : ProcedureReturn : EndIf
  AddAIService(Name, URL, 1)
  SelectedAI = Trim(Name)
  UpdateTargetURL()
  SaveCustomAIServices()
  UpdateSettingsUI()
EndProcedure

Procedure RemoveSelectedCustomAI()
  ForEach AIServices()
    If LCase(AIServices()\Name) = LCase(SelectedAI) And AIServices()\IsCustom
      DeleteElement(AIServices())
      SelectedAI = "Gemini"
      UpdateTargetURL()
      SaveCustomAIServices()
      UpdateSettingsUI()
      ProcedureReturn
    EndIf
  Next
  MessageRequester(Txt_CustomAINotCustomTitle, Txt_CustomAINotCustomMsg, #PB_MessageRequester_Info)
EndProcedure

; ----------------------------------------------------------------------------
; 3. KEYBOARD HOOK LOGIC
; ----------------------------------------------------------------------------
Procedure.i CheckActiveModifiers()
  Protected ModFlags.i = 0
  If (GetAsyncKeyState_(#VK_CONTROL) & $8000) : ModFlags | #HOTKEY_MOD_CTRL : EndIf
  If (GetAsyncKeyState_(#VK_MENU)    & $8000) : ModFlags | #HOTKEY_MOD_ALT  : EndIf
  If (GetAsyncKeyState_(#VK_SHIFT)   & $8000) : ModFlags | #HOTKEY_MOD_SHIFT : EndIf
  If (GetAsyncKeyState_(#VK_LWIN)    & $8000) Or (GetAsyncKeyState_(#VK_RWIN) & $8000) : ModFlags | #HOTKEY_MOD_WIN : EndIf
  ProcedureReturn ModFlags
EndProcedure

Procedure.l KeyboardProc(nCode, wParam, lParam)
  Protected *pkbdll.KBDLLHOOKSTRUCT = lParam
  Protected EffMode.i, EffLaunchMode.i, EffPaused.i
  Protected EffURL.s
  Protected VKey.w
  Protected CurMods.i
  
  If nCode < 0 : ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam) : EndIf
  If *pkbdll\flags & $10 : ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam) : EndIf

  If RecordDlgOpen
    If wParam = #WM_KEYDOWN Or wParam = #WM_SYSKEYDOWN
      Select *pkbdll\vkCode
        Case #VK_LCONTROL, #VK_RCONTROL, #VK_CONTROL, #VK_LMENU, #VK_RMENU, #VK_MENU,
             #VK_LSHIFT, #VK_RSHIFT, #VK_SHIFT, #VK_LWIN, #VK_RWIN
        Default
          RecordedVK = *pkbdll\vkCode
          RecordedModifiers = CheckActiveModifiers()
          RecordedKeyName = FormatKeyCombo(RecordedVK, RecordedModifiers)
          PostEvent(#Event_HotkeyCaptured)
          ProcedureReturn 1
      EndSelect
    EndIf
    ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
  EndIf

  If *pkbdll\vkCode = TriggerVK
    CurMods = CheckActiveModifiers()
    If TriggerModifiers <> 0 And CurMods <> TriggerModifiers
      ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
    EndIf
    
    EffMode = ButtonMode
    EffLaunchMode = LaunchMode
    EffPaused = MappingPaused
    EffURL = TargetURL
    
    If CachedProfileActive
      If CachedProfilePaused = 1
        EffPaused = 1
      ElseIf CachedProfilePaused = 0 And MappingPaused = 0
        EffPaused = 0
      EndIf
      If CachedProfileMode >= 0 And CachedProfileMode <= 2 : EffMode = CachedProfileMode : EndIf
      If CachedProfileLaunchMode >= 0 And CachedProfileLaunchMode <= 3 : EffLaunchMode = CachedProfileLaunchMode : EndIf
      If CachedProfileAIURL <> "" : EffURL = CachedProfileAIURL : EndIf
    EndIf
    
    If EffPaused
      CopilotKeyDown = 0
      ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
    EndIf
    
    If wParam = #WM_KEYDOWN Or wParam = #WM_SYSKEYDOWN
      If CopilotKeyDown = 0
        CopilotKeyDown = 1
        Select EffMode
          Case 0 
            PendingLaunchURL = EffURL
            PendingLaunchMode = EffLaunchMode
            PostEvent(#Event_OpenCopilot)
          Case 1, 2 
            If EffMode = 1 : VKey = #VK_RCONTROL : Else : VKey = #VK_RMENU : EndIf
            ActiveRemapVKey = VKey
            If GetAsyncKeyState_(#VK_LSHIFT) & $8000 : SendKeyInput(#VK_LSHIFT, #KEYEVENTF_KEYUP) : EndIf
            If GetAsyncKeyState_(#VK_LWIN) & $8000 : SendKeyInput(#VK_LWIN, #KEYEVENTF_KEYUP) : EndIf
            SendKeyInput(VKey, 0)
        EndSelect
      EndIf
      ProcedureReturn 1
    ElseIf wParam = #WM_KEYUP Or wParam = #WM_SYSKEYUP
      If ActiveRemapVKey <> 0
        SendKeyInput(ActiveRemapVKey, #KEYEVENTF_KEYUP)
        ActiveRemapVKey = 0
      EndIf
      CopilotKeyDown = 0
      ProcedureReturn 1
    EndIf
    ProcedureReturn 1
  EndIf

  ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
EndProcedure

; ----------------------------------------------------------------------------
; 4. APPLICATION INITIALIZATION & MAIN LOOP
; ----------------------------------------------------------------------------
SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", GetPathPart(ProgramFilename()) + "WebViewData")

GetAvailableLanguages() 
LoadAIServices()
GetInstalledBrowsers()
LoadSettings()
LoadAppProfiles()
UpdateLanguageStrings()
UpdateActiveProfileCache()

If OpenWindow(#MainWin, 0, 0, 0, 0, "AICopilotMapper", #PB_Window_Invisible)
  
  CatchImage(#AppIcon, ?AppIconStart, ?AppIconEnd - ?AppIconStart)
  AddSysTrayIcon(#TrayIcon, WindowID(#MainWin), ImageID(#AppIcon))
  SysTrayIconToolTip(#TrayIcon, Txt_TrayTooltip)
  RebuildMenu()
  
  hHook = SetWindowsHookEx_(13, @KeyboardProc(), GetModuleHandle_(0), 0)
  If hHook = 0
    MessageRequester("Keyboard hook fejl", "Kunne ikke installere keyboard hook.", #PB_MessageRequester_Error)
  EndIf
  
  AddWindowTimer(#MainWin, #ProfileCacheTimerID, #ProfileCacheIntervalMs)
  
  Repeat
    Define Event.i = WaitWindowEvent()
    
    If Event = #PB_Event_SizeWindow And EventWindow() = #AIWin
      ResizeGadget(#AIGadget, 0, 35, WindowWidth(#AIWin), WindowHeight(#AIWin) - 35)
    EndIf
    
    Select Event      
      Case #Event_OpenCopilot
        LaunchTarget(PendingLaunchURL, PendingLaunchMode)
        
      Case #Event_HotkeyCaptured
        TriggerVK = RecordedVK
        TriggerModifiers = RecordedModifiers
        TriggerKeyName = RecordedKeyName
        RecordDlgOpen = 0
        If IsWindow(#HotkeyWin) : CloseWindow(#HotkeyWin) : EndIf
        SaveSettings()
        UpdateTrayTooltip()
        UpdateSettingsUI()
        
      Case #PB_Event_Gadget
        Select EventGadget()
          Case #AICombo
            Define sIdx.i = GetGadgetState(#AICombo)
            If sIdx >= 0
              SelectElement(AIServices(), sIdx)
              SelectedAI = AIServices()\Name
              UpdateTargetURL()
              SetGadgetText(#AIGadget, TargetURL)
              SaveSettings()
              UpdateTrayTooltip()
            EndIf
            
          Case #Set_BtnRecordKey
            OpenHotkeyRecorder()
            
          Case #Set_BtnResetKey
            TriggerVK = $86
            TriggerModifiers = 0
            TriggerKeyName = "Copilot-tast"
            SaveSettings()
            UpdateTrayTooltip()
            UpdateSettingsUI()
            
          Case #Set_ComboMode
            ButtonMode = GetGadgetState(#Set_ComboMode)
            SaveSettings()
            UpdateTrayTooltip()
            
          Case #Set_ComboAI
            sIdx = GetGadgetState(#Set_ComboAI)
            If sIdx >= 0
              SelectElement(AIServices(), sIdx)
              SelectedAI = AIServices()\Name
              UpdateTargetURL()
              SaveSettings()
              UpdateTrayTooltip()
            EndIf
            
          Case #Set_BtnAddAI
            AddOrEditCustomAI()
            
          Case #Set_BtnDelAI
            RemoveSelectedCustomAI()
            
          Case #Set_ChkEmbedded
            UseEmbeddedBrowser = GetGadgetState(#Set_ChkEmbedded)
            DisableGadget(#Set_ComboBrowser, UseEmbeddedBrowser)
            DisableGadget(#Set_ComboLaunchMode, UseEmbeddedBrowser)
            SaveSettings()
            UpdateTrayTooltip()
            
          Case #Set_ComboBrowser
            sIdx = GetGadgetState(#Set_ComboBrowser)
            If sIdx >= 0
              SelectElement(InstalledBrowsers(), sIdx)
              BrowserPath = InstalledBrowsers()\Path
              SaveSettings()
            EndIf
            
          Case #Set_ComboLaunchMode
            LaunchMode = GetGadgetState(#Set_ComboLaunchMode)
            SaveSettings()
            UpdateTrayTooltip()
            
          Case #Set_ChkAutoStart
            Define NewAutoStart.i = GetGadgetState(#Set_ChkAutoStart)
            If SetAutoStartRegistry(NewAutoStart)
              AutoStart = NewAutoStart
              SaveSettings()
            Else
              SetGadgetState(#Set_ChkAutoStart, AutoStart)
            EndIf
            
          Case #Set_ComboLang
            sIdx = GetGadgetState(#Set_ComboLang)
            If sIdx >= 0
              SelectElement(AvailableLanguages(), sIdx)
              Language = AvailableLanguages()\Code
              UpdateLanguageStrings()
              SaveSettings()
              RebuildMenu()
              UpdateSettingsUI()
            EndIf
            
          Case #Set_BtnOpenProfiles
            OpenProfileFile()
            
          Case #Set_BtnReloadProfiles
            LoadAppProfiles()
            UpdateActiveProfileCache()
            MessageRequester(Txt_ProfileReloadedTitle, Txt_ProfileReloadedMsg, #PB_MessageRequester_Info)
            
          Case #Set_BtnSaveClose
            CloseWindow(#SettingsWin)
            
          Case #Hotkey_BtnCancel
            RecordDlgOpen = 0
            If IsWindow(#HotkeyWin) : CloseWindow(#HotkeyWin) : EndIf
        EndSelect
        
      Case #PB_Event_CloseWindow
        Select EventWindow()
          Case #AIWin
            CloseWindow(#AIWin)
          Case #HotkeyWin
            RecordDlgOpen = 0
            CloseWindow(#HotkeyWin)
          Case #SettingsWin
            CloseWindow(#SettingsWin)
          Case #MainWin
            Break
        EndSelect

      Case #PB_Event_SysTray
        If EventType() = #PB_EventType_RightClick Or EventType() = #PB_EventType_LeftClick
          DisplayPopupMenu(#TrayMenu, WindowID(#MainWin))
        EndIf
        
      Case #PB_Event_Timer
        If EventTimer() = #ProfileCacheTimerID And EventWindow() = #MainWin
          UpdateActiveProfileCache()
        EndIf
        
      Case #PB_Event_Menu
        Select EventMenu()
          Case #Menu_Tray_OpenAI
            LaunchTarget(TargetURL, LaunchMode)
            
          Case #Menu_Tray_Pause
            MappingPaused = 1 - MappingPaused
            CopilotKeyDown = 0
            If ActiveRemapVKey <> 0
              SendKeyInput(ActiveRemapVKey, #KEYEVENTF_KEYUP)
              ActiveRemapVKey = 0
            EndIf
            RebuildMenu()
            
          Case #Menu_Tray_Settings
            OpenSettingsWindow()
            
          Case #Menu_Tray_About
            MessageRequester(Txt_AboutTitle, Txt_AboutText, #PB_MessageRequester_Info)
            
          Case #Menu_Tray_Exit
            Break
        EndSelect
    EndSelect
  ForEver

  ; --------------------------------------------------------------------------
  ; 5. CLEANUP 
  ; --------------------------------------------------------------------------
  RemoveWindowTimer(#MainWin, #ProfileCacheTimerID)
  If IsWindow(#AIWin) : CloseWindow(#AIWin) : EndIf
  If IsWindow(#SettingsWin) : CloseWindow(#SettingsWin) : EndIf
  If IsWindow(#HotkeyWin) : CloseWindow(#HotkeyWin) : EndIf
  If ActiveRemapVKey <> 0 : SendKeyInput(ActiveRemapVKey, #KEYEVENTF_KEYUP) : EndIf
  If hHook : UnhookWindowsHookEx_(hHook) : EndIf
  RemoveSysTrayIcon(#TrayIcon)
  If hMutex : CloseHandle_(hMutex) : EndIf
EndIf

DataSection
  AppIconStart: 
    IncludeBinary "aicopilotmapper.ico"
  AppIconEnd:
EndDataSection
; IDE Options = PureBasic 6.40 (Windows - x64)
; CursorPosition = 918
; FirstLine = 886
; Folding = -------
; EnableXP
; DPIAware
; UseIcon = aicopilotmapper.ico
; Executable = ..\AICopilotMapper.exe
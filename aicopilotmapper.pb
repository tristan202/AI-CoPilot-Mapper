; ============================================================================
; Application: AI Copilot Mapper
; Version: 1.5.0
; Description: Remaps the Windows Copilot key (or custom hotkey) to AI services.
;              Features an embedded WebView2 browser and per-app profile support.
; ============================================================================

EnableExplicit

; ----------------------------------------------------------------------------
; EXTERNAL API IMPORTS
; ----------------------------------------------------------------------------
Import "Kernel32.lib"
  QueryFullProcessImageNameW(hProcess.i, dwFlags.l, lpExeName.i, lpdwSize.i)
EndImport

; --- CONSTANTS ---
#AppVersion = "1.5.0"

; Modifier flag-konstanter til brugerdefinerede genveje
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

; Custom Hotkey Indstillinger ($86 = Copilot / F23 hardware standard)
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
Global Txt_TrayTooltip.s, Txt_MenuBrowser.s, Txt_MenuAI.s
Global Txt_MenuAutoStart.s, Txt_MenuLanguage.s, Txt_MenuAbout.s, Txt_MenuExit.s
Global Txt_AboutTitle.s, Txt_AboutText.s
Global Txt_MenuMode.s, Txt_ModeAI.s, Txt_ModeCTRL.s, Txt_ModeALT.s
Global Txt_MenuLaunchMode.s, Txt_LaunchApp.s, Txt_LaunchTab.s, Txt_LaunchWindow.s, Txt_LaunchDefault.s
Global Txt_MenuPause.s, Txt_MenuProfiles.s, Txt_ProfileOpen.s, Txt_ProfileReload.s, Txt_ProfileTemplate.s
Global Txt_CustomAIAdd.s, Txt_CustomAIRemove.s
Global Txt_MenuEmbedded.s 
Global Txt_CustomAINamePrompt.s, Txt_CustomAIURLPrompt.s
Global Txt_CustomAINotCustomTitle.s, Txt_CustomAINotCustomMsg.s
Global Txt_RegErrorTitle.s, Txt_RegErrorMsg.s
Global Txt_ProfileReloadedTitle.s, Txt_ProfileReloadedMsg.s
Global Txt_MenuHotkey.s, Txt_HotkeyConfigure.s, Txt_HotkeyReset.s, Txt_HotkeyCurrent.s

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
  #HotkeyWin
  #Hotkey_TextPrompt
  #Hotkey_TextStatus
  #Hotkey_BtnCancel
  #TrayMenu
  #TrayIcon
  #AppIcon
  #Menu_Mode_AI
  #Menu_Mode_CTRL
  #Menu_Mode_ALT
  #Menu_Launch_App
  #Menu_Launch_Tab
  #Menu_Launch_Window
  #Menu_Launch_Default
  #Menu_Embedded
  #Menu_AutoStart
  #Menu_Pause
  #Menu_CustomAI_Add
  #Menu_CustomAI_Remove
  #Menu_Hotkey_Config
  #Menu_Hotkey_Reset
  #Menu_Profile_Open
  #Menu_Profile_Reload
  #Menu_Profile_Template
  #Menu_About
  #Menu_Exit
  #Menu_Browser_Base = 1000 
  #Menu_Lang_Base    = 2000 
  #Menu_AI_Base      = 3000 
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

; Konverterer en Virtual-Key code og modifiers til en læsbar tekststreng
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
EndProcedure

Procedure RemoveSelectedCustomAI()
  ForEach AIServices()
    If LCase(AIServices()\Name) = LCase(SelectedAI) And AIServices()\IsCustom
      DeleteElement(AIServices())
      SelectedAI = "Gemini"
      UpdateTargetURL()
      SaveCustomAIServices()
      ProcedureReturn
    EndIf
  Next
  MessageRequester(Txt_CustomAINotCustomTitle, Txt_CustomAINotCustomMsg, #PB_MessageRequester_Info)
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

; ----------------------------------------------------------------------------
; CORE LOGIC: WINDOW & BROWSER LAUNCHERS
; ----------------------------------------------------------------------------
Procedure PopulateAICombo()
  Protected i.i
  ClearGadgetItems(#AICombo)
  ForEach AIServices()
    AddGadgetItem(#AICombo, -1, AIServices()\Name)
  Next
  For i = 0 To CountGadgetItems(#AICombo) - 1
    If LCase(GetGadgetItemText(#AICombo, i)) = LCase(SelectedAI)
      SetGadgetState(#AICombo, i)
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
    PopulateAICombo()
    ProcedureReturn
  EndIf
  
  If OpenWindow(#AIWin, #PB_Ignore, #PB_Ignore, 1024, 768, "AI Copilot View", #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_MaximizeGadget)
    StickyWindow(#AIWin, 1)
    SetActiveWindow(#AIWin)
    StickyWindow(#AIWin, 0)
    ComboBoxGadget(#AICombo, 10, 5, 250, 25)
    PopulateAICombo()
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
; LOCALIZATION & SYSTEM TRAY
; ----------------------------------------------------------------------------
Procedure UpdateLanguageStrings()
  Protected AppName.s = "AI Copilot Mapper"
  Protected VerPrefix.s = " v" + #AppVersion + Chr(10)
  Protected LngFile.s = GetPathPart(ProgramFilename()) + Language + ".lng"
  
  Txt_MenuMode = "Knap Funktion" : Txt_ModeAI = "AI Genvej" : Txt_ModeCTRL = "Højre CTRL" : Txt_ModeALT = "Højre ALT"
  Txt_MenuAI = "Vælg AI" : Txt_MenuBrowser = "Vælg Browser" : Txt_MenuAutoStart = "Start med Windows"
  Txt_MenuLanguage = "Sprog" : Txt_MenuExit = "Afslut" : Txt_MenuAbout = "Om programmet"
  Txt_MenuLaunchMode = "Åbningsmetode" : Txt_LaunchApp = "App-vindue" : Txt_LaunchTab = "Normal fane" : Txt_LaunchWindow = "Nyt vindue" : Txt_LaunchDefault = "Systemstandard"
  Txt_MenuPause = "Pause mapping"
  Txt_MenuProfiles = "Profiler pr. app"
  Txt_ProfileOpen = "Åbn profil-fil"
  Txt_ProfileReload = "Genindlæs profiler"
  Txt_ProfileTemplate = "Opret profil-skabelon"
  Txt_CustomAIAdd = "Tilføj/ret custom AI..."
  Txt_CustomAIRemove = "Fjern valgt custom AI"
  Txt_MenuEmbedded = "Brug Indbygget View (Hurtig)"
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
  
  If FileSize(LngFile) > 0
    If OpenPreferences(LngFile, #PB_UTF8)
      PreferenceGroup("Language")
      Txt_MenuMode = ReadPreferenceString("MenuMode", Txt_MenuMode)
      Txt_ModeAI = ReadPreferenceString("ModeAI", Txt_ModeAI)
      Txt_ModeCTRL = ReadPreferenceString("ModeCTRL", Txt_ModeCTRL)
      Txt_ModeALT = ReadPreferenceString("ModeALT", Txt_ModeALT)
      Txt_MenuAI = ReadPreferenceString("MenuAI", Txt_MenuAI)
      Txt_MenuBrowser = ReadPreferenceString("MenuBrowser", Txt_MenuBrowser)
      Txt_MenuAutoStart = ReadPreferenceString("MenuAutoStart", Txt_MenuAutoStart)
      Txt_MenuLanguage = ReadPreferenceString("MenuLanguage", Txt_MenuLanguage)
      Txt_MenuExit = ReadPreferenceString("MenuExit", Txt_MenuExit)
      Txt_MenuAbout = ReadPreferenceString("MenuAbout", Txt_MenuAbout)
      Txt_MenuLaunchMode = ReadPreferenceString("MenuLaunchMode", Txt_MenuLaunchMode)
      Txt_LaunchApp = ReadPreferenceString("LaunchApp", Txt_LaunchApp)
      Txt_LaunchTab = ReadPreferenceString("LaunchTab", Txt_LaunchTab)
      Txt_LaunchWindow = ReadPreferenceString("LaunchWindow", Txt_LaunchWindow)
      Txt_LaunchDefault = ReadPreferenceString("LaunchDefault", Txt_LaunchDefault)
      Txt_MenuPause = ReadPreferenceString("MenuPause", Txt_MenuPause)
      Txt_MenuProfiles = ReadPreferenceString("MenuProfiles", Txt_MenuProfiles)
      Txt_ProfileOpen = ReadPreferenceString("ProfileOpen", Txt_ProfileOpen)
      Txt_ProfileReload = ReadPreferenceString("ProfileReload", Txt_ProfileReload)
      Txt_ProfileTemplate = ReadPreferenceString("ProfileTemplate", Txt_ProfileTemplate)
      Txt_CustomAIAdd = ReadPreferenceString("CustomAIAdd", Txt_CustomAIAdd)
      Txt_CustomAIRemove = ReadPreferenceString("CustomAIRemove", Txt_CustomAIRemove)
      Txt_MenuEmbedded = ReadPreferenceString("MenuEmbedded", Txt_MenuEmbedded)
      Txt_AboutTitle = ReadPreferenceString("AboutTitle", Txt_AboutTitle)
      Txt_AboutText = AppName + VerPrefix + ReadPreferenceString("AboutText", "Developed to remap hotkeys and Copilot keys.")
      Txt_MsgBoxRunning = ReadPreferenceString("MsgBoxRunning", Txt_MsgBoxRunning)
      Txt_CustomAINamePrompt = ReadPreferenceString("CustomAINamePrompt", Txt_CustomAINamePrompt)
      Txt_CustomAIURLPrompt = ReadPreferenceString("CustomAIURLPrompt", Txt_CustomAIURLPrompt)
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
    Tip + "Status: Paused" + Chr(10)
  EndIf
  Tip + "Genvej: " + TriggerKeyName + Chr(10)
  Tip + "AI: " + SelectedAI + Chr(10)
  Tip + "Mode: "
  Select ButtonMode
    Case 0 : Tip + Txt_ModeAI
    Case 1 : Tip + Txt_ModeCTRL
    Case 2 : Tip + Txt_ModeALT
  EndSelect
  If UseEmbeddedBrowser
    Tip + Chr(10) + "Åbning: WebView2 (Embedded)"
  Else
    Tip + Chr(10) + "Åbning: " + LaunchModeName(LaunchMode)
  EndIf
  SysTrayIconToolTip(#TrayIcon, Tip)
EndProcedure

Procedure RebuildMenu()
  Protected Index.i = 0
  If IsMenu(#TrayMenu)
    FreeMenu(#TrayMenu)
  EndIf
  
  If CreatePopupMenu(#TrayMenu)
    OpenSubMenu(Txt_MenuMode)
      MenuItem(#Menu_Mode_AI, Txt_ModeAI)
      MenuItem(#Menu_Mode_CTRL, Txt_ModeCTRL)
      MenuItem(#Menu_Mode_ALT, Txt_ModeALT)
    CloseSubMenu()
    MenuBar()
    
    OpenSubMenu(Txt_MenuHotkey)
      MenuItem(#Menu_Hotkey_Config, Txt_HotkeyConfigure)
      MenuItem(#Menu_Hotkey_Reset, Txt_HotkeyReset)
      MenuBar()
      MenuItem(9999, Txt_HotkeyCurrent + TriggerKeyName)
      DisableMenuItem(#TrayMenu, 9999, 1)
    CloseSubMenu()
    
    OpenSubMenu(Txt_MenuAI)
      Index = 0
      ForEach AIServices()
        If AIServices()\IsCustom
          MenuItem(#Menu_AI_Base + Index, AIServices()\Name + " (Custom)")
        Else
          Select AIServices()\Name
            Case "Gemini"     : MenuItem(#Menu_AI_Base + Index, "Google Gemini")
            Case "ChatGPT"    : MenuItem(#Menu_AI_Base + Index, "OpenAI ChatGPT")
            Case "Claude"     : MenuItem(#Menu_AI_Base + Index, "Anthropic Claude")
            Case "Perplexity" : MenuItem(#Menu_AI_Base + Index, "Perplexity AI")
            Case "Copilot"    : MenuItem(#Menu_AI_Base + Index, "Microsoft Copilot (Web)")
            Default           : MenuItem(#Menu_AI_Base + Index, AIServices()\Name)
          EndSelect
        EndIf
        If LCase(SelectedAI) = LCase(AIServices()\Name)
          SetMenuItemState(#TrayMenu, #Menu_AI_Base + Index, 1)
        EndIf
        Index + 1
      Next
      MenuBar()
      MenuItem(#Menu_CustomAI_Add, Txt_CustomAIAdd)
      MenuItem(#Menu_CustomAI_Remove, Txt_CustomAIRemove)
    CloseSubMenu()
    
    OpenSubMenu(Txt_MenuBrowser)
      Index = 0
      ForEach InstalledBrowsers()
        MenuItem(#Menu_Browser_Base + Index, InstalledBrowsers()\Name)
        If LCase(BrowserPath) = LCase(InstalledBrowsers()\Path)
          SetMenuItemState(#TrayMenu, #Menu_Browser_Base + Index, 1)
        EndIf
        Index + 1
      Next
    CloseSubMenu()
    
    OpenSubMenu(Txt_MenuLaunchMode)
      MenuItem(#Menu_Launch_App, Txt_LaunchApp)
      MenuItem(#Menu_Launch_Tab, Txt_LaunchTab)
      MenuItem(#Menu_Launch_Window, Txt_LaunchWindow)
      MenuItem(#Menu_Launch_Default, Txt_LaunchDefault)
    CloseSubMenu()
    
    MenuBar()
    MenuItem(#Menu_Embedded, Txt_MenuEmbedded)
    MenuItem(#Menu_AutoStart, Txt_MenuAutoStart)
    MenuItem(#Menu_Pause, Txt_MenuPause)
    
    OpenSubMenu(Txt_MenuProfiles)
      MenuItem(#Menu_Profile_Open, Txt_ProfileOpen)
      MenuItem(#Menu_Profile_Reload, Txt_ProfileReload)
      MenuItem(#Menu_Profile_Template, Txt_ProfileTemplate)
    CloseSubMenu()
    
    OpenSubMenu(Txt_MenuLanguage)
      Index = 0
      ForEach AvailableLanguages()
        MenuItem(#Menu_Lang_Base + Index, AvailableLanguages()\Name)
        If UCase(Language) = UCase(AvailableLanguages()\Code)
          SetMenuItemState(#TrayMenu, #Menu_Lang_Base + Index, 1)
        EndIf
        Index + 1
      Next
    CloseSubMenu()
    
    MenuBar()
    MenuItem(#Menu_About, Txt_MenuAbout)
    MenuItem(#Menu_Exit, Txt_MenuExit)
    
    SetMenuItemState(#TrayMenu, #Menu_Mode_AI, Bool(ButtonMode = 0))
    SetMenuItemState(#TrayMenu, #Menu_Mode_CTRL, Bool(ButtonMode = 1))
    SetMenuItemState(#TrayMenu, #Menu_Mode_ALT, Bool(ButtonMode = 2))
    SetMenuItemState(#TrayMenu, #Menu_Launch_App, Bool(LaunchMode = 0))
    SetMenuItemState(#TrayMenu, #Menu_Launch_Tab, Bool(LaunchMode = 1))
    SetMenuItemState(#TrayMenu, #Menu_Launch_Window, Bool(LaunchMode = 2))
    SetMenuItemState(#TrayMenu, #Menu_Launch_Default, Bool(LaunchMode = 3))
    SetMenuItemState(#TrayMenu, #Menu_Embedded, UseEmbeddedBrowser) 
    SetMenuItemState(#TrayMenu, #Menu_AutoStart, AutoStart)
    SetMenuItemState(#TrayMenu, #Menu_Pause, MappingPaused)
  EndIf
  
  UpdateTrayTooltip()
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
; DIALOG: OPELÆS/OPTAG NY GENVEJ
; ----------------------------------------------------------------------------
Procedure OpenHotkeyRecorder()
  If IsWindow(#HotkeyWin)
    SetActiveWindow(#HotkeyWin)
    ProcedureReturn
  EndIf
  
  RecordDlgOpen = 1
  RecordedVK = 0
  RecordedModifiers = 0
  RecordedKeyName = ""
  
  If OpenWindow(#HotkeyWin, #PB_Ignore, #PB_Ignore, 360, 140, "Indstil Genvejstast", #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
    StickyWindow(#HotkeyWin, 1)
    TextGadget(#Hotkey_TextPrompt, 20, 20, 320, 35, "Tryk på den ønskede tastekombination nu..." + Chr(10) + "(F.eks. Ctrl+Alt+Mellemrum, F12, Win+Shift+A)")
    TextGadget(#Hotkey_TextStatus, 20, 65, 320, 25, "Venter på tastetryk...", #PB_Text_Center)
    ButtonGadget(#Hotkey_BtnCancel, 130, 95, 100, 30, "Annuller")
  EndIf
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
  
  If nCode < 0
    ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
  EndIf
  If *pkbdll\flags & $10
    ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
  EndIf

  ; Modus: Optag ny brugerdefineret tast
  If RecordDlgOpen
    If wParam = #WM_KEYDOWN Or wParam = #WM_SYSKEYDOWN
      Select *pkbdll\vkCode
        Case #VK_LCONTROL, #VK_RCONTROL, #VK_CONTROL, #VK_LMENU, #VK_RMENU, #VK_MENU,
             #VK_LSHIFT, #VK_RSHIFT, #VK_SHIFT, #VK_LWIN, #VK_RWIN
          ; Ignorer standalone modifiers indtil hovedtasten rammes
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

  ; Tjek om tastetryk matcher den aktive udløsertast
  If *pkbdll\vkCode = TriggerVK
    CurMods = CheckActiveModifiers()
    
    ; Hvis tasten har modifiers, skal de matche
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
      
      If CachedProfileMode >= 0 And CachedProfileMode <= 2
        EffMode = CachedProfileMode
      EndIf
      
      If CachedProfileLaunchMode >= 0 And CachedProfileLaunchMode <= 3
        EffLaunchMode = CachedProfileLaunchMode
      EndIf
      
      If CachedProfileAIURL <> ""
        EffURL = CachedProfileAIURL
      EndIf
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
            
            If GetAsyncKeyState_(#VK_LSHIFT) & $8000
              SendKeyInput(#VK_LSHIFT, #KEYEVENTF_KEYUP)
            EndIf
            If GetAsyncKeyState_(#VK_LWIN) & $8000
              SendKeyInput(#VK_LWIN, #KEYEVENTF_KEYUP)
            EndIf
            
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
        
      ; Udløst når brugeren har trykket en gyldig tastekombination i optageren
      Case #Event_HotkeyCaptured
        TriggerVK = RecordedVK
        TriggerModifiers = RecordedModifiers
        TriggerKeyName = RecordedKeyName
        RecordDlgOpen = 0
        If IsWindow(#HotkeyWin)
          CloseWindow(#HotkeyWin)
        EndIf
        SaveSettings()
        RebuildMenu()
        MessageRequester("Genvej opdateret", "Ny genvej aktiveret: " + TriggerKeyName, #PB_MessageRequester_Info)
        
      Case #PB_Event_Gadget
        If EventGadget() = #AICombo
          Define SelectedIdx.i = GetGadgetState(#AICombo)
          If SelectedIdx >= 0
            SelectElement(AIServices(), SelectedIdx)
            SelectedAI = AIServices()\Name
            UpdateTargetURL()
            SetGadgetText(#AIGadget, TargetURL)
            SaveSettings()
            RebuildMenu()
          EndIf
        ElseIf EventGadget() = #Hotkey_BtnCancel
          RecordDlgOpen = 0
          If IsWindow(#HotkeyWin) : CloseWindow(#HotkeyWin) : EndIf
        EndIf
        
      Case #PB_Event_CloseWindow
        If EventWindow() = #AIWin
          CloseWindow(#AIWin)
        ElseIf EventWindow() = #HotkeyWin
          RecordDlgOpen = 0
          CloseWindow(#HotkeyWin)
        Else
          Break
        EndIf

      Case #PB_Event_SysTray
        If EventType() = #PB_EventType_RightClick Or EventType() = #PB_EventType_LeftClick
          DisplayPopupMenu(#TrayMenu, WindowID(#MainWin))
        EndIf
        
      Case #PB_Event_Timer
        If EventTimer() = #ProfileCacheTimerID And EventWindow() = #MainWin
          UpdateActiveProfileCache()
        EndIf
        
      Case #PB_Event_Menu
        Define MenuID.i = EventMenu()
        
        If MenuID >= #Menu_Browser_Base And MenuID < #Menu_Browser_Base + ListSize(InstalledBrowsers())
          SelectElement(InstalledBrowsers(), MenuID - #Menu_Browser_Base)
          BrowserPath = InstalledBrowsers()\Path : SaveSettings() : RebuildMenu()
          
        ElseIf MenuID >= #Menu_Lang_Base And MenuID < #Menu_Lang_Base + ListSize(AvailableLanguages())
          SelectElement(AvailableLanguages(), MenuID - #Menu_Lang_Base)
          Language = AvailableLanguages()\Code
          UpdateLanguageStrings() : SaveSettings() : RebuildMenu()
          
        ElseIf MenuID >= #Menu_AI_Base And MenuID < #Menu_AI_Base + ListSize(AIServices())
          SelectElement(AIServices(), MenuID - #Menu_AI_Base)
          SelectedAI = AIServices()\Name
          UpdateTargetURL() : SaveSettings() : RebuildMenu()
          
        Else
          Select MenuID
            Case #Menu_Mode_AI    : ButtonMode = 0 : SaveSettings() : RebuildMenu()
            Case #Menu_Mode_CTRL  : ButtonMode = 1 : SaveSettings() : RebuildMenu()
            Case #Menu_Mode_ALT   : ButtonMode = 2 : SaveSettings() : RebuildMenu()
            
            Case #Menu_Hotkey_Config
              OpenHotkeyRecorder()
              
            Case #Menu_Hotkey_Reset
              TriggerVK = $86
              TriggerModifiers = 0
              TriggerKeyName = "Copilot-tast"
              SaveSettings()
              RebuildMenu()
              MessageRequester("Genvej nulstillet", "Genvejen er sat tilbage til standard Copilot-tasten.", #PB_MessageRequester_Info)
            
            Case #Menu_Launch_App     : LaunchMode = 0 : SaveSettings() : RebuildMenu()
            Case #Menu_Launch_Tab     : LaunchMode = 1 : SaveSettings() : RebuildMenu()
            Case #Menu_Launch_Window  : LaunchMode = 2 : SaveSettings() : RebuildMenu()
            Case #Menu_Launch_Default : LaunchMode = 3 : SaveSettings() : RebuildMenu()
            
            Case #Menu_Embedded
              UseEmbeddedBrowser = 1 - UseEmbeddedBrowser
              SaveSettings() : RebuildMenu()

            Case #Menu_CustomAI_Add
              AddOrEditCustomAI()
              SaveSettings() : RebuildMenu()
              
            Case #Menu_CustomAI_Remove
              RemoveSelectedCustomAI()
              SaveSettings() : RebuildMenu()

            Case #Menu_AutoStart
              Define NewAutoStart.i = 1 - AutoStart
              If SetAutoStartRegistry(NewAutoStart)
                AutoStart = NewAutoStart
                SaveSettings()
              EndIf
              RebuildMenu()
              
            Case #Menu_Pause
              MappingPaused = 1 - MappingPaused
              CopilotKeyDown = 0
              If ActiveRemapVKey <> 0
                SendKeyInput(ActiveRemapVKey, #KEYEVENTF_KEYUP)
                ActiveRemapVKey = 0
              EndIf
              RebuildMenu()
              
            Case #Menu_Profile_Open     : OpenProfileFile()
            Case #Menu_Profile_Reload
              LoadAppProfiles()
              UpdateActiveProfileCache()
              MessageRequester(Txt_ProfileReloadedTitle, Txt_ProfileReloadedMsg, #PB_MessageRequester_Info)
              RebuildMenu()
              
            Case #Menu_Profile_Template : CreateProfileTemplate(1) : OpenProfileFile()
            Case #Menu_About            : MessageRequester(Txt_AboutTitle, Txt_AboutText, #PB_MessageRequester_Info)
            Case #Menu_Exit             : Break
          EndSelect
        EndIf
    EndSelect
  ForEver

  ; --------------------------------------------------------------------------
  ; 5. CLEANUP 
  ; --------------------------------------------------------------------------
  RemoveWindowTimer(#MainWin, #ProfileCacheTimerID)
  If IsWindow(#AIWin) : CloseWindow(#AIWin) : EndIf
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
; CursorPosition = 40
; Folding = ------
; EnableXP
; DPIAware
; UseIcon = aicopilotmapper.ico
; Executable = ..\AICopilotMapper.exe
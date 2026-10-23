; ============================================================================
; Application: AI Copilot Mapper
; Version: see #AppVersion
; Description: Remaps the Windows Copilot key (or custom hotkey) to AI services.
;              Features an embedded WebView2 browser, settings UI and profiles.
; ============================================================================

EnableExplicit

; ----------------------------------------------------------------------------
; EXTERNAL API IMPORTS
; ----------------------------------------------------------------------------
Import "Kernel32.lib"
  QueryFullProcessImageNameW(hProcess.i, dwFlags.l, lpExeName.i, lpdwSize.i)
  GetUserDefaultUILanguage.w()
EndImport

; --- CONSTANTS ---
#AppName    = "AI Copilot Mapper"
#AppVersion = "1.6.2"
#GitHubURL  = "https://github.com/tristan202/AI-CoPilot-Mapper"

#HOTKEY_MOD_ALT   = $01
#HOTKEY_MOD_CTRL  = $02
#HOTKEY_MOD_SHIFT = $04
#HOTKEY_MOD_WIN   = $08

; The Copilot key is sent by Windows as Win + Shift + F23
#VK_COPILOT = $86

CompilerIf Not Defined(WH_KEYBOARD_LL, #PB_Constant)
  #WH_KEYBOARD_LL = 13
CompilerEndIf
CompilerIf Not Defined(LLKHF_INJECTED, #PB_Constant)
  #LLKHF_INJECTED = $10
CompilerEndIf
CompilerIf Not Defined(PROCESS_QUERY_LIMITED_INFORMATION, #PB_Constant)
  #PROCESS_QUERY_LIMITED_INFORMATION = $1000
CompilerEndIf
CompilerIf Not Defined(ERROR_ALREADY_EXISTS, #PB_Constant)
  #ERROR_ALREADY_EXISTS = 183
CompilerEndIf
CompilerIf Not Defined(ERROR_MORE_DATA, #PB_Constant)
  #ERROR_MORE_DATA = 234
CompilerEndIf
CompilerIf Not Defined(ERROR_FILE_NOT_FOUND, #PB_Constant)
  #ERROR_FILE_NOT_FOUND = 2
CompilerEndIf
CompilerIf Not Defined(LOCALE_SISO639LANGNAME, #PB_Constant)
  #LOCALE_SISO639LANGNAME = $59
CompilerEndIf

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

; Localized strings, keyed by the names used in the .lng files
Global NewMap Txt.s()

Global PendingLaunchURL.s = ""
Global PendingLaunchMode.i = 0

Global IniFile.s = GetPathPart(ProgramFilename()) + "AICopilotMapper.ini"
Global ProfileFile.s = GetPathPart(ProgramFilename()) + "AICopilotMapper_profiles.ini"
Global BrowserPath.s = ""
Global SelectedAI.s = "Gemini"
Global TargetURL.s = "https://gemini.google.com"
Global AutoStart.i = 0
Global Language.s = "EN"

; Custom Hotkey
Global TriggerVK.w = #VK_COPILOT
Global TriggerModifiers.i = 0

; Operating Modes
Global ButtonMode.i = 0
Global LaunchMode.i = 0
Global UseEmbeddedBrowser.i = 1
Global MappingPaused.i = 0

; Keyboard Hook States
Global CopilotKeyDown.i = 0
Global ActiveRemapVKey.w = 0
Global hMutex.i, hHook.i
Global AboutIconImage.i

; Hook capture modal state
Global RecordDlgOpen.i = 0
Global RecordedVK.w = 0
Global RecordedModifiers.i = 0

; Cached per-app profile state
Global CachedProfileActive.i = 0
Global CachedProfileMode.i = -1
Global CachedProfileLaunchMode.i = -1
Global CachedProfileAIURL.s = ""
Global CachedProfilePaused.i = -1
#ProfileCacheTimerID = 1
#ProfileCacheIntervalMs = 250

; ----------------------------------------------------------------------------
; ENUMERATIONS
; ----------------------------------------------------------------------------
Enumeration #PB_Event_FirstCustomValue
  #Event_OpenCopilot
  #Event_HotkeyCaptured
  #Event_HotkeyCancelled
EndEnumeration

Enumeration
  #AboutWin
  #About_ImageGadget
  #About_LinkGadget
  #About_TextGadget
  #About_TitleText
  #About_CloseBtn
  #MainWin
  #AIWin
  #AICombo
  #AIAboutBtn
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
; 1. HELPER FUNCTIONS
; ----------------------------------------------------------------------------
Procedure.s T(Key.s)
  If FindMapElement(Txt(), Key)
    ProcedureReturn Txt()
  EndIf
  ProcedureReturn Key
EndProcedure

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

Procedure.i BrowserIsFirefox()
  ProcedureReturn Bool(FindString(LCase(GetFilePart(BrowserPath)), "firefox") > 0)
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

Procedure ReleaseRemappedKey()
  If ActiveRemapVKey <> 0
    SendKeyInput(ActiveRemapVKey, #KEYEVENTF_KEYUP)
    ActiveRemapVKey = 0
  EndIf
EndProcedure

Procedure.s ReadRegString(hKeyRoot, KeyPath.s, ValueName.s)
  Protected hKey.i, Type.i, BufferSize.i, Result.s = ""
  Protected *Buffer, QueryResult.i

  If RegOpenKeyEx_(hKeyRoot, KeyPath, 0, #KEY_READ, @hKey) = #ERROR_SUCCESS
    BufferSize = 0
    QueryResult = RegQueryValueEx_(hKey, ValueName, 0, @Type, 0, @BufferSize)
    If (QueryResult = #ERROR_SUCCESS Or QueryResult = #ERROR_MORE_DATA) And BufferSize > 0
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
    AvailableLanguages()\Code = "EN"
    AvailableLanguages()\Name = "English"
  EndIf
EndProcedure

Procedure.i IsLanguageAvailable(Code.s)
  ForEach AvailableLanguages()
    If UCase(AvailableLanguages()\Code) = UCase(Code)
      ProcedureReturn 1
    EndIf
  Next
  ProcedureReturn 0
EndProcedure

; Picks the Windows display language if a matching .lng file exists, else English
Procedure.s DetectSystemLanguage()
  Protected Buffer.s = Space(16)
  Protected Code.s
  If GetLocaleInfo_(GetUserDefaultUILanguage(), #LOCALE_SISO639LANGNAME, @Buffer, 16) > 0
    Code = UCase(Trim(Buffer))
    If IsLanguageAvailable(Code) : ProcedureReturn Code : EndIf
  EndIf
  If IsLanguageAvailable("EN") Or FirstElement(AvailableLanguages()) = 0
    ProcedureReturn "EN"
  EndIf
  ProcedureReturn AvailableLanguages()\Code
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

; Returns "" when no service with that name exists
Procedure.s GetAIURLByName(Name.s)
  ForEach AIServices()
    If LCase(AIServices()\Name) = LCase(Name)
      ProcedureReturn AIServices()\URL
    EndIf
  Next
  ProcedureReturn ""
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
  If TargetURL = "" And FirstElement(AIServices())
    SelectedAI = AIServices()\Name
    TargetURL = AIServices()\URL
  EndIf
EndProcedure

Procedure.s FormatKeyCombo(vkCode.w, Modifiers.i)
  Protected Text.s = ""

  ; The physical Copilot key always arrives with Win + Shift held
  If vkCode = #VK_COPILOT And (Modifiers & ~(#HOTKEY_MOD_WIN | #HOTKEY_MOD_SHIFT)) = 0
    ProcedureReturn T("CopilotKey")
  EndIf

  If Modifiers & #HOTKEY_MOD_CTRL  : Text + "Ctrl + "  : EndIf
  If Modifiers & #HOTKEY_MOD_ALT   : Text + "Alt + "   : EndIf
  If Modifiers & #HOTKEY_MOD_SHIFT : Text + "Shift + " : EndIf
  If Modifiers & #HOTKEY_MOD_WIN   : Text + "Win + "   : EndIf

  Select vkCode
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
          Text + T("KeyCode") + " $" + Hex(vkCode)
        EndIf
      EndIf
  EndSelect
  ProcedureReturn Text
EndProcedure

; Keys that are safe to use without a modifier, since they don't type anything
Procedure.i IsStandaloneHotkey(vkCode.w)
  Select vkCode
    Case #VK_F1 To #VK_F24 : ProcedureReturn 1
    Case $A6 To $B7        : ProcedureReturn 1 ; Browser, volume, media and launch keys
  EndSelect
  ProcedureReturn 0
EndProcedure

Procedure.s LaunchModeName(Mode.i)
  Select Mode
    Case 0 : ProcedureReturn T("LaunchApp")
    Case 1 : ProcedureReturn T("LaunchTab")
    Case 2 : ProcedureReturn T("LaunchWindow")
    Case 3 : ProcedureReturn T("LaunchDefault")
  EndSelect
  ProcedureReturn T("LaunchApp")
EndProcedure

Procedure.i GetGadgetTextWidth(GadgetID.i, Text.s)
  Protected hDC.i, Size.SIZE, Font.i, OldFont.i, Width.i = 85

  If IsGadget(GadgetID)
    hDC = GetDC_(GadgetID(GadgetID))
    If hDC
      Font = SendMessage_(GadgetID(GadgetID), #WM_GETFONT, 0, 0)
      If Font : OldFont = SelectObject_(hDC, Font) : EndIf

      If GetTextExtentPoint32_(hDC, Text, Len(Text), @Size)
        ; Measured in physical pixels; gadget coordinates are DPI-scaled units
        Width = DesktopUnscaledX(Size\cx) + 20 ; +20 px padding til knappens ramme
      EndIf

      If OldFont : SelectObject_(hDC, OldFont) : EndIf
      ReleaseDC_(GadgetID(GadgetID), hDC)
    EndIf
  EndIf

  ProcedureReturn Width
EndProcedure

; Height needed to show word-wrapped text in a gadget of the given width
Procedure.i GetGadgetTextHeight(GadgetID.i, Text.s, Width.i)
  Protected hDC.i, Rect.RECT, Font.i, OldFont.i, Height.i = 20

  If IsGadget(GadgetID)
    hDC = GetDC_(GadgetID(GadgetID))
    If hDC
      Font = SendMessage_(GadgetID(GadgetID), #WM_GETFONT, 0, 0)
      If Font : OldFont = SelectObject_(hDC, Font) : EndIf

      Rect\right = DesktopScaledX(Width)
      If DrawText_(hDC, Text, -1, @Rect, #DT_CALCRECT | #DT_WORDBREAK | #DT_NOPREFIX)
        Height = DesktopUnscaledY(Rect\bottom - Rect\top)
      EndIf

      If OldFont : SelectObject_(hDC, OldFont) : EndIf
      ReleaseDC_(GadgetID(GadgetID), hDC)
    EndIf
  EndIf

  ProcedureReturn Height
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

; Draws a blue circle with a white "i" on a transparent background
Procedure.i CreateInfoIcon(Size.i)
  Protected Image.i = CreateImage(#PB_Any, Size, Size, 32, #PB_Image_Transparent)
  Protected Center.d = Size / 2.0
  Protected StemW.d = Size * 0.14

  If Image = 0 : ProcedureReturn 0 : EndIf
  If StartVectorDrawing(ImageVectorOutput(Image))
    AddPathCircle(Center, Center, Center - 0.5)
    VectorSourceColor(RGBA(0, 103, 192, 255))
    FillPath()

    VectorSourceColor(RGBA(255, 255, 255, 255))
    AddPathCircle(Center, Size * 0.29, Size * 0.09)
    FillPath()
    AddPathBox(Center - StemW / 2, Size * 0.43, StemW, Size * 0.33)
    FillPath()
    StopVectorDrawing()
  EndIf
  ProcedureReturn Image
EndProcedure

Procedure.s AIWindowTitle()
  ProcedureReturn T("AIWindowTitle") + " v" + #AppVersion
EndProcedure

; Keeps the About button right-aligned in the top row and the WebView filling the rest
Procedure LayoutAIWindow()
  If Not IsWindow(#AIWin) : ProcedureReturn : EndIf
  ; 16x16 icon, vertically centred on the 25 px high AI selector
  ResizeGadget(#AIAboutBtn, WindowWidth(#AIWin) - 16 - 14, 9, 16, 16)
  If IsGadget(#AIGadget)
    ResizeGadget(#AIGadget, 0, 35, WindowWidth(#AIWin), WindowHeight(#AIWin) - 35)
  EndIf
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

  If OpenWindow(#AIWin, #PB_Ignore, #PB_Ignore, 1024, 768, AIWindowTitle(), #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_MaximizeGadget)
    StickyWindow(#AIWin, 1)
    SetActiveWindow(#AIWin)
    StickyWindow(#AIWin, 0)
    ComboBoxGadget(#AICombo, 10, 5, 250, 25)
    PopulateAICombo(#AICombo)
    ; Icon-only button with an information icon
    If AboutIconImage = 0 : AboutIconImage = CreateInfoIcon(DesktopScaledX(16)) : EndIf
    If AboutIconImage
      ; Borderless: a clickable ImageGadget instead of a button
      ImageGadget(#AIAboutBtn, 0, 9, 16, 16, ImageID(AboutIconImage))
    Else
      ButtonGadget(#AIAboutBtn, 0, 5, 30, 25, "?")
    EndIf
    GadgetToolTip(#AIAboutBtn, T("MenuAbout"))
    If WebViewGadget(#AIGadget, 0, 35, 1024, 768 - 35)
      SetGadgetText(#AIGadget, URL)
    EndIf
    LayoutAIWindow()
  EndIf
EndProcedure

Procedure OpenAboutWindow()
  Static TitleFont.i
  Protected ParentID.i, TextH.i, LinkY.i, BtnY.i, CenterFlag.i = #PB_Window_ScreenCentered

  If IsWindow(#AboutWin)
    SetActiveWindow(#AboutWin)
    ProcedureReturn
  EndIf

  ; Owned by the AI window when it is open, so it stays in front of it
  If IsWindow(#AIWin)
    ParentID = WindowID(#AIWin)
    CenterFlag = #PB_Window_WindowCentered
  EndIf

  ; Opened hidden so it can be sized to fit the description before it is shown
  If OpenWindow(#AboutWin, 0, 0, 400, 245, T("AboutTitle"), #PB_Window_SystemMenu | #PB_Window_Invisible, ParentID)
    If TitleFont = 0 : TitleFont = LoadFont(#PB_Any, "Segoe UI", 12, #PB_Font_Bold) : EndIf

    ImageGadget(#About_ImageGadget, 20, 20, 48, 48, ImageID(#AppIcon))
    TextGadget(#About_TitleText, 85, 20, 295, 26, #AppName + " v" + #AppVersion)
    If TitleFont : SetGadgetFont(#About_TitleText, FontID(TitleFont)) : EndIf

    TextGadget(#About_TextGadget, 85, 52, 295, 20, T("AboutText"))
    TextH = GetGadgetTextHeight(#About_TextGadget, T("AboutText"), 295)
    ResizeGadget(#About_TextGadget, #PB_Ignore, #PB_Ignore, #PB_Ignore, TextH)

    LinkY = 52 + TextH + 12
    If LinkY < 80 : LinkY = 80 : EndIf
    HyperLinkGadget(#About_LinkGadget, 85, LinkY, 295, 20, #GitHubURL, RGB(0, 102, 204), #PB_HyperLink_Underline)

    BtnY = LinkY + 38
    ButtonGadget(#About_CloseBtn, 140, BtnY, 120, 30, T("BtnClose"))

    ResizeWindow(#AboutWin, #PB_Ignore, #PB_Ignore, #PB_Ignore, BtnY + 45)
    HideWindow(#AboutWin, 0, CenterFlag)
  EndIf
EndProcedure

Procedure LaunchTarget(URL.s, UseLaunchMode.i)
  Protected Args.s, QuotedURL.s

  If UseEmbeddedBrowser = 1
    OpenEmbeddedAI(URL)
    ProcedureReturn
  EndIf

  URL = NormalizeURL(URL)
  If URL = "" : ProcedureReturn : EndIf
  QuotedURL = #DQUOTE$ + URL + #DQUOTE$

  Select UseLaunchMode
    Case 0
      ; Firefox has no --app mode, so a new window is the closest match
      If BrowserIsFirefox()
        Args = "--new-window " + QuotedURL
      Else
        Args = "--app=" + QuotedURL
      EndIf
    Case 1
      Args = QuotedURL
    Case 2
      Args = "--new-window " + QuotedURL
    Default
      Args = ""
  EndSelect

  If Args <> "" And BrowserIsExplicit()
    RunProgram(BrowserPath, Args, "")
  Else
    RunProgram(URL, "", "")
  EndIf
EndProcedure

; ----------------------------------------------------------------------------
; SETTINGS & PROFILE MANAGEMENT
; ----------------------------------------------------------------------------
Procedure.i SetAutoStartRegistry(Enable.i)
  Protected hKey.i, Result.i
  Protected KeyPath.s = "Software\Microsoft\Windows\CurrentVersion\Run"
  Protected ValueName.s = "AICopilotMapper"
  Protected Path.s = #DQUOTE$ + ProgramFilename() + #DQUOTE$
  Protected DataSize.i = StringByteLength(Path) + SizeOf(Character)

  Result = RegOpenKeyEx_(#HKEY_CURRENT_USER, KeyPath, 0, #KEY_SET_VALUE, @hKey)
  If Result = #ERROR_SUCCESS
    If Enable
      Result = RegSetValueEx_(hKey, ValueName, 0, #REG_SZ, @Path, DataSize)
    Else
      Result = RegDeleteValue_(hKey, ValueName)
      If Result = #ERROR_FILE_NOT_FOUND : Result = #ERROR_SUCCESS : EndIf
    EndIf
    RegCloseKey_(hKey)
  EndIf

  If Result <> #ERROR_SUCCESS
    MessageRequester(T("RegErrorTitle"), T("RegErrorMsg") + #LF$ + T("ErrorCode") + ": " + Str(Result), #PB_MessageRequester_Warning)
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
    ; The key name is now derived from VK + modifiers in the current language
    RemovePreferenceKey("CustomKeyName")
    ClosePreferences()
  EndIf
EndProcedure

Procedure LoadSettings()
  Language = ""
  If OpenPreferences(IniFile, #PB_UTF8)
    PreferenceGroup("Settings")
    BrowserPath = ReadPreferenceString("Browser", "")
    AutoStart = ReadPreferenceInteger("AutoStart", 0)
    Language = ReadPreferenceString("Language", "")
    SelectedAI = ReadPreferenceString("AI", "Gemini")
    ButtonMode = ReadPreferenceInteger("ButtonMode", 0)
    LaunchMode = ReadPreferenceInteger("LaunchMode", 0)
    UseEmbeddedBrowser = ReadPreferenceInteger("UseEmbeddedBrowser", 1)
    TriggerVK = ReadPreferenceInteger("CustomKeyVK", #VK_COPILOT)
    TriggerModifiers = ReadPreferenceInteger("CustomKeyModifiers", 0)
    ClosePreferences()
  EndIf

  If Language = "" Or IsLanguageAvailable(Language) = 0
    Language = DetectSystemLanguage()
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
  If TriggerVK <= 0 : TriggerVK = #VK_COPILOT : TriggerModifiers = 0 : EndIf
  UpdateTargetURL()
EndProcedure

Procedure CreateProfileTemplate(Overwrite.i)
  Protected File.i
  If FileSize(ProfileFile) >= 0 And Overwrite = 0 : ProcedureReturn : EndIf

  File = CreateFile(#PB_Any, ProfileFile, #PB_UTF8)
  If File
    WriteStringN(File, "; " + T("ProfileTemplateTitle"))
    WriteStringN(File, "; " + T("ProfileTemplateHint"))
    WriteStringN(File, ";")
    WriteStringN(File, "; 1Process=notepad.exe")
    WriteStringN(File, "; 1Mode=-1        (-1, 0=" + T("ModeAI") + ", 1=" + T("ModeCTRL") + ", 2=" + T("ModeALT") + ")")
    WriteStringN(File, "; 1AIName=ChatGPT")
    WriteStringN(File, "; 1AIURL=")
    WriteStringN(File, "; 1LaunchMode=-1  (-1, 0=" + T("LaunchApp") + ", 1=" + T("LaunchTab") + ", 2=" + T("LaunchWindow") + ", 3=" + T("LaunchDefault") + ")")
    WriteStringN(File, "; 1Paused=-1      (-1, 0, 1)")
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
  RunProgram("notepad.exe", #DQUOTE$ + ProfileFile + #DQUOTE$, "")
EndProcedure

Procedure.s GetActiveProcessName()
  Protected hWnd.i, PID.l, hProcess.i
  Protected Buffer.s = Space(1024), Size.l = 1024
  Protected Result.s = ""

  hWnd = GetForegroundWindow_()
  If hWnd = 0 : ProcedureReturn "" : EndIf
  GetWindowThreadProcessId_(hWnd, @PID)
  If PID = 0 : ProcedureReturn "" : EndIf

  hProcess = OpenProcess_(#PROCESS_QUERY_LIMITED_INFORMATION, 0, PID)
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
  Protected Key.s, Value.s
  Protected LngFile.s = GetPathPart(ProgramFilename()) + Language + ".lng"

  ; Built-in English fallbacks, so a missing key or .lng file never shows blank text
  ClearMap(Txt())
  Restore DefaultStrings
  Repeat
    Read.s Key
    If Key = "" : Break : EndIf
    Read.s Value
    Txt(Key) = ReplaceString(Value, "\n", #LF$)
  ForEver

  ; Overlay every key from the selected language file
  If FileSize(LngFile) > 0 And OpenPreferences(LngFile, #PB_UTF8)
    If PreferenceGroup("Language")
      ExaminePreferenceKeys()
      While NextPreferenceKey()
        Txt(PreferenceKeyName()) = ReplaceString(PreferenceKeyValue(), "\n", #LF$)
      Wend
    EndIf
    ClosePreferences()
  EndIf
EndProcedure

Procedure.s HotkeyLabel()
  ProcedureReturn RTrim(T("HotkeyCurrent")) + " " + FormatKeyCombo(TriggerVK, TriggerModifiers)
EndProcedure

Procedure UpdateTrayTooltip()
  Protected Tip.s
  Tip = #AppName + " v" + #AppVersion + #LF$
  If MappingPaused
    Tip + T("TrayPaused") + #LF$
  EndIf
  Tip + HotkeyLabel() + #LF$
  Tip + "AI: " + SelectedAI + #LF$
  If UseEmbeddedBrowser
    Tip + T("TrayViewEmbedded")
  Else
    Tip + T("TrayViewExternal") + " (" + LaunchModeName(LaunchMode) + ")"
  EndIf
  SysTrayIconToolTip(#TrayIcon, Tip)
EndProcedure

Procedure RebuildMenu()
  If IsMenu(#TrayMenu)
    FreeMenu(#TrayMenu)
  EndIf

  If CreatePopupMenu(#TrayMenu)
    MenuItem(#Menu_Tray_OpenAI, T("MenuOpenAI"))
    MenuItem(#Menu_Tray_Pause, T("MenuPause"))
    MenuBar()
    MenuItem(#Menu_Tray_Settings, T("MenuSettings"))
    MenuBar()
    MenuItem(#Menu_Tray_About, T("MenuAbout"))
    MenuItem(#Menu_Tray_Exit, T("MenuExit"))

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
  Protected BtnAddW.i = GetGadgetTextWidth(#Set_BtnAddAI, T("BtnAddCustom"))
  Protected BtnDelW.i = GetGadgetTextWidth(#Set_BtnDelAI, T("BtnRemoveSelected"))
  If BtnAddW < 90 : BtnAddW = 90 : EndIf
  If BtnDelW < 90 : BtnDelW = 90 : EndIf

  ; Mål knapperne i øverste sektion (Optag/Nulstil)
  Protected BtnRecW.i = GetGadgetTextWidth(#Set_BtnRecordKey, T("BtnRecord"))
  Protected BtnRstW.i = GetGadgetTextWidth(#Set_BtnResetKey, T("BtnReset"))
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
  SetWindowTitle(#SettingsWin, T("SettingsTitle"))

  ; 1. Genvej & Tastfunktion
  ResizeGadget(#Set_FrameKey, 15, 10, FrameW, 95)
  SetGadgetText(#Set_FrameKey, T("FrameHotkey"))
  SetGadgetText(#Set_KeyLabel, HotkeyLabel())
  ResizeGadget(#Set_BtnResetKey, RightEdge - 15 - BtnRstW, 28, BtnRstW, 25)
  SetGadgetText(#Set_BtnResetKey, T("BtnReset"))
  ResizeGadget(#Set_BtnRecordKey, RightEdge - 25 - BtnRstW - BtnRecW, 28, BtnRecW, 25)
  SetGadgetText(#Set_BtnRecordKey, T("BtnRecord"))
  ResizeGadget(#Set_KeyLabel, 30, 32, RightEdge - 35 - BtnRstW - BtnRecW - 30, 20)

  SetGadgetText(#Set_LabelBtnAction, T("LabelButtonAction"))
  ResizeGadget(#Set_ComboMode, 150, 65, FrameW - 145, 25)
  ClearGadgetItems(#Set_ComboMode)
  AddGadgetItem(#Set_ComboMode, -1, T("ModeAI"))
  AddGadgetItem(#Set_ComboMode, -1, T("ModeCTRL"))
  AddGadgetItem(#Set_ComboMode, -1, T("ModeALT"))
  SetGadgetState(#Set_ComboMode, ButtonMode)

  ; 2. AI Tjeneste (Dynamisk tilpasning af knapper og dropdown)
  ResizeGadget(#Set_FrameAI, 15, 115, FrameW, 75)
  SetGadgetText(#Set_FrameAI, T("FrameAI"))

  Protected DelX.i = RightEdge - 15 - BtnDelW
  Protected AddX.i = DelX - 10 - BtnAddW
  Protected ComboAIW.i = AddX - 10 - 30

  ResizeGadget(#Set_ComboAI, 30, 142, ComboAIW, 25)
  PopulateAICombo(#Set_ComboAI)

  ResizeGadget(#Set_BtnAddAI, AddX, 142, BtnAddW, 25)
  SetGadgetText(#Set_BtnAddAI, T("BtnAddCustom"))

  ResizeGadget(#Set_BtnDelAI, DelX, 142, BtnDelW, 25)
  SetGadgetText(#Set_BtnDelAI, T("BtnRemoveSelected"))

  ; 3. Browser Integration
  ResizeGadget(#Set_FrameBrowser, 15, 200, FrameW, 115)
  SetGadgetText(#Set_FrameBrowser, T("FrameBrowser"))
  ResizeGadget(#Set_ChkEmbedded, 30, 222, FrameW - 30, 20)
  SetGadgetText(#Set_ChkEmbedded, T("MenuEmbedded"))
  SetGadgetState(#Set_ChkEmbedded, UseEmbeddedBrowser)

  SetGadgetText(#Set_LabelBrowser, T("LabelExternalBrowser"))
  ResizeGadget(#Set_ComboBrowser, 150, 248, FrameW - 145, 25)

  SetGadgetText(#Set_LabelLaunchMode, T("MenuLaunchMode") + ":")
  ResizeGadget(#Set_ComboLaunchMode, 150, 278, FrameW - 145, 25)

  DisableGadget(#Set_ComboBrowser, UseEmbeddedBrowser)
  DisableGadget(#Set_ComboLaunchMode, UseEmbeddedBrowser)

  Protected bIdx.i = 0
  ClearGadgetItems(#Set_ComboBrowser)
  ForEach InstalledBrowsers()
    AddGadgetItem(#Set_ComboBrowser, -1, InstalledBrowsers()\Name)
    If LCase(BrowserPath) = LCase(InstalledBrowsers()\Path)
      bIdx = ListIndex(InstalledBrowsers())
    EndIf
  Next
  SetGadgetState(#Set_ComboBrowser, bIdx)

  ClearGadgetItems(#Set_ComboLaunchMode)
  AddGadgetItem(#Set_ComboLaunchMode, -1, T("LaunchApp"))
  AddGadgetItem(#Set_ComboLaunchMode, -1, T("LaunchTab"))
  AddGadgetItem(#Set_ComboLaunchMode, -1, T("LaunchWindow"))
  AddGadgetItem(#Set_ComboLaunchMode, -1, T("LaunchDefault"))
  SetGadgetState(#Set_ComboLaunchMode, LaunchMode)

  ; 4. System & Profiler
  ResizeGadget(#Set_FrameSystem, 15, 325, FrameW, 105)
  SetGadgetText(#Set_FrameSystem, T("FrameSystem"))
  SetGadgetText(#Set_ChkAutoStart, T("MenuAutoStart"))
  SetGadgetState(#Set_ChkAutoStart, AutoStart)

  ResizeGadget(#Set_LabelLang, 240, 350, 60, 20)
  SetGadgetText(#Set_LabelLang, T("MenuLanguage") + ":")
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
  SetGadgetText(#Set_BtnOpenProfiles, T("BtnOpenProfiles"))
  ResizeGadget(#Set_BtnReloadProfiles, 30 + HalfBtnW + 15, 385, HalfBtnW, 26)
  SetGadgetText(#Set_BtnReloadProfiles, T("BtnReloadProfiles"))

  ; Luk-knap centreres
  ResizeGadget(#Set_BtnSaveClose, (WinW / 2) - 60, 440, 120, 30)
  SetGadgetText(#Set_BtnSaveClose, T("BtnClose"))
EndProcedure

Procedure OpenSettingsWindow()
  If IsWindow(#SettingsWin)
    SetActiveWindow(#SettingsWin)
    ProcedureReturn
  EndIf

  If OpenWindow(#SettingsWin, #PB_Ignore, #PB_Ignore, 520, 485, T("SettingsTitle"), #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
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

  RecordedVK = 0
  RecordedModifiers = 0

  If OpenWindow(#HotkeyWin, #PB_Ignore, #PB_Ignore, 360, 140, T("MenuHotkey"), #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
    StickyWindow(#HotkeyWin, 1)
    TextGadget(#Hotkey_TextPrompt, 20, 15, 320, 40, T("HotkeyPrompt"))
    TextGadget(#Hotkey_TextStatus, 20, 65, 320, 25, T("HotkeyWaiting"), #PB_Text_Center)
    ButtonGadget(#Hotkey_BtnCancel, 130, 95, 100, 30, T("HotkeyCancel"))
    RecordDlgOpen = 1
  EndIf
EndProcedure

Procedure CloseHotkeyRecorder()
  RecordDlgOpen = 0
  If IsWindow(#HotkeyWin) : CloseWindow(#HotkeyWin) : EndIf
EndProcedure

Procedure ApplyRecordedHotkey()
  Protected Answer.i
  CloseHotkeyRecorder()
  If RecordedVK = 0 : ProcedureReturn : EndIf

  ; A plain typing key would be swallowed everywhere in Windows
  If RecordedModifiers = 0 And IsStandaloneHotkey(RecordedVK) = 0
    Answer = MessageRequester(T("MenuHotkey"), FormatKeyCombo(RecordedVK, RecordedModifiers) + #LF$ + #LF$ + T("HotkeyNoModifierWarn"), #PB_MessageRequester_YesNo | #PB_MessageRequester_Warning)
    If Answer <> #PB_MessageRequester_Yes : ProcedureReturn : EndIf
  EndIf

  TriggerVK = RecordedVK
  TriggerModifiers = RecordedModifiers
  SaveSettings()
  UpdateTrayTooltip()
  UpdateSettingsUI()
EndProcedure

Procedure AddOrEditCustomAI()
  Protected Name.s, URL.s
  Name = InputRequester(T("CustomAINotCustomTitle"), T("CustomAINamePrompt"), "")
  If Trim(Name) = "" : ProcedureReturn : EndIf
  URL = InputRequester(T("CustomAINotCustomTitle"), T("CustomAIURLPrompt"), "http://localhost:3000")
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
  MessageRequester(T("CustomAINotCustomTitle"), T("CustomAINotCustomMsg"), #PB_MessageRequester_Info)
EndProcedure

; ----------------------------------------------------------------------------
; 2. KEYBOARD HOOK LOGIC
; ----------------------------------------------------------------------------
Procedure.i CheckActiveModifiers()
  Protected ModFlags.i = 0
  If (GetAsyncKeyState_(#VK_CONTROL) & $8000) : ModFlags | #HOTKEY_MOD_CTRL : EndIf
  If (GetAsyncKeyState_(#VK_MENU)    & $8000) : ModFlags | #HOTKEY_MOD_ALT  : EndIf
  If (GetAsyncKeyState_(#VK_SHIFT)   & $8000) : ModFlags | #HOTKEY_MOD_SHIFT : EndIf
  If (GetAsyncKeyState_(#VK_LWIN)    & $8000) Or (GetAsyncKeyState_(#VK_RWIN) & $8000) : ModFlags | #HOTKEY_MOD_WIN : EndIf
  ProcedureReturn ModFlags
EndProcedure

Procedure.i KeyboardProc(nCode, wParam, lParam)
  Protected *pkbdll.KBDLLHOOKSTRUCT = lParam
  Protected EffMode.i, EffLaunchMode.i, EffPaused.i
  Protected EffURL.s
  Protected VKey.w

  If nCode < 0 : ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam) : EndIf
  If *pkbdll\flags & #LLKHF_INJECTED : ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam) : EndIf

  If RecordDlgOpen
    If wParam = #WM_KEYDOWN Or wParam = #WM_SYSKEYDOWN
      Select *pkbdll\vkCode
        Case #VK_LCONTROL, #VK_RCONTROL, #VK_CONTROL, #VK_LMENU, #VK_RMENU, #VK_MENU,
             #VK_LSHIFT, #VK_RSHIFT, #VK_SHIFT, #VK_LWIN, #VK_RWIN
        Case #VK_ESCAPE
          RecordDlgOpen = 0
          PostEvent(#Event_HotkeyCancelled)
          ProcedureReturn 1
        Default
          ; Stop recording right away so a following requester can be used normally
          RecordDlgOpen = 0
          RecordedVK = *pkbdll\vkCode
          RecordedModifiers = CheckActiveModifiers()
          PostEvent(#Event_HotkeyCaptured)
          ProcedureReturn 1
      EndSelect
    EndIf
    ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
  EndIf

  If *pkbdll\vkCode = TriggerVK
    If wParam = #WM_KEYUP Or wParam = #WM_SYSKEYUP
      ; Always finish a press we handled, even if its modifiers were released
      ; first or the mapping was paused while the key was held down
      If CopilotKeyDown
        ReleaseRemappedKey()
        CopilotKeyDown = 0
        ProcedureReturn 1
      EndIf
      ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
    EndIf

    ; Swallow auto-repeat of a press we are already handling
    If CopilotKeyDown : ProcedureReturn 1 : EndIf

    If TriggerModifiers <> 0 And CheckActiveModifiers() <> TriggerModifiers
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
      ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
    EndIf

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
    ProcedureReturn 1
  EndIf

  ProcedureReturn CallNextHookEx_(hHook, nCode, wParam, lParam)
EndProcedure

; ----------------------------------------------------------------------------
; 3. APPLICATION INITIALIZATION & MAIN LOOP
; ----------------------------------------------------------------------------
GetAvailableLanguages()
LoadAIServices()
GetInstalledBrowsers()
LoadSettings()
UpdateLanguageStrings()

; --- Instance check (per user session) ---
Define MutexName.s = "Local\AICopilotMapper_Unique_ID"
hMutex = CreateMutex_(0, 1, @MutexName)
If GetLastError_() = #ERROR_ALREADY_EXISTS
  MessageRequester(#AppName, T("MsgBoxRunning"), #PB_MessageRequester_Info)
  End
EndIf

SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", GetPathPart(ProgramFilename()) + "WebViewData")

LoadAppProfiles()
UpdateActiveProfileCache()

If OpenWindow(#MainWin, 0, 0, 0, 0, "AICopilotMapper", #PB_Window_Invisible)

  CatchImage(#AppIcon, ?AppIconStart, ?AppIconEnd - ?AppIconStart)
  AddSysTrayIcon(#TrayIcon, WindowID(#MainWin), ImageID(#AppIcon))
  SysTrayIconToolTip(#TrayIcon, #AppName)
  RebuildMenu()

  hHook = SetWindowsHookEx_(#WH_KEYBOARD_LL, @KeyboardProc(), GetModuleHandle_(0), 0)
  If hHook = 0
    MessageRequester(T("HookErrorTitle"), T("HookErrorMsg"), #PB_MessageRequester_Error)
  EndIf

  AddWindowTimer(#MainWin, #ProfileCacheTimerID, #ProfileCacheIntervalMs)

  Repeat
    Define Event.i = WaitWindowEvent()
    Define sIdx.i

    If Event = #PB_Event_SizeWindow And EventWindow() = #AIWin
      LayoutAIWindow()
    EndIf

    Select Event
      Case #Event_OpenCopilot
        LaunchTarget(PendingLaunchURL, PendingLaunchMode)

      Case #Event_HotkeyCaptured
        ApplyRecordedHotkey()

      Case #Event_HotkeyCancelled
        CloseHotkeyRecorder()

      Case #PB_Event_Gadget
        Select EventGadget()
          Case #AICombo
            sIdx = GetGadgetState(#AICombo)
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
            TriggerVK = #VK_COPILOT
            TriggerModifiers = 0
            SaveSettings()
            UpdateTrayTooltip()
            UpdateSettingsUI()

          Case #Set_ComboMode
            sIdx = GetGadgetState(#Set_ComboMode)
            If sIdx >= 0
              ButtonMode = sIdx
              SaveSettings()
              UpdateTrayTooltip()
            EndIf

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
            sIdx = GetGadgetState(#Set_ComboLaunchMode)
            If sIdx >= 0
              LaunchMode = sIdx
              SaveSettings()
              UpdateTrayTooltip()
            EndIf

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
              If IsWindow(#AIWin)
                SetWindowTitle(#AIWin, AIWindowTitle())
                GadgetToolTip(#AIAboutBtn, T("MenuAbout"))
                LayoutAIWindow()
              EndIf
              If IsWindow(#AboutWin) : CloseWindow(#AboutWin) : EndIf
            EndIf

          Case #Set_BtnOpenProfiles
            OpenProfileFile()

          Case #Set_BtnReloadProfiles
            LoadAppProfiles()
            UpdateActiveProfileCache()
            MessageRequester(T("ProfileReloadedTitle"), T("ProfileReloadedMsg"), #PB_MessageRequester_Info)

          Case #Set_BtnSaveClose
            CloseWindow(#SettingsWin)

          Case #Hotkey_BtnCancel
            CloseHotkeyRecorder()

          Case #AIAboutBtn
            If EventType() = #PB_EventType_LeftClick Or GadgetType(#AIAboutBtn) = #PB_GadgetType_Button
              OpenAboutWindow()
            EndIf

          Case #About_LinkGadget
            RunProgram(#GitHubURL, "", "")

          Case #About_CloseBtn
            CloseWindow(#AboutWin)
        EndSelect

      Case #PB_Event_CloseWindow
        Select EventWindow()
          Case #AIWin
            CloseWindow(#AIWin)
          Case #HotkeyWin
            CloseHotkeyRecorder()
          Case #AboutWin
            CloseWindow(#AboutWin)
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
            ReleaseRemappedKey()
            RebuildMenu()

          Case #Menu_Tray_Settings
            OpenSettingsWindow()

          Case #Menu_Tray_About
            OpenAboutWindow()

          Case #Menu_Tray_Exit
            Break
        EndSelect
    EndSelect
  ForEver

  ; --------------------------------------------------------------------------
  ; 4. CLEANUP
  ; --------------------------------------------------------------------------
  RemoveWindowTimer(#MainWin, #ProfileCacheTimerID)
  If IsWindow(#AIWin) : CloseWindow(#AIWin) : EndIf
  If IsWindow(#SettingsWin) : CloseWindow(#SettingsWin) : EndIf
  If IsWindow(#HotkeyWin) : CloseWindow(#HotkeyWin) : EndIf
  If IsWindow(#AboutWin) : CloseWindow(#AboutWin) : EndIf
  ReleaseRemappedKey()
  If hHook : UnhookWindowsHookEx_(hHook) : EndIf
  RemoveSysTrayIcon(#TrayIcon)
  If hMutex : CloseHandle_(hMutex) : EndIf
EndIf

DataSection
  AppIconStart:
    IncludeBinary "aicopilotmapper.ico"
  AppIconEnd:

  ; Built-in English strings: key, value. Overridden by the selected .lng file.
  DefaultStrings:
  Data.s "ModeAI", "AI Shortcut"
  Data.s "ModeCTRL", "Right CTRL"
  Data.s "ModeALT", "Right ALT"
  Data.s "MenuPause", "Pause mapping"
  Data.s "MenuAbout", "About"
  Data.s "MenuExit", "Exit"
  Data.s "MenuSettings", "Settings..."
  Data.s "MenuOpenAI", "Open AI View"
  Data.s "MenuLaunchMode", "Launch Mode"
  Data.s "MenuEmbedded", "Use Embedded WebView2 (Fast)"
  Data.s "MenuAutoStart", "Start with Windows"
  Data.s "MenuLanguage", "Language"
  Data.s "MenuHotkey", "Hotkey"
  Data.s "LaunchApp", "App window"
  Data.s "LaunchTab", "Normal tab"
  Data.s "LaunchWindow", "New window"
  Data.s "LaunchDefault", "System default"
  Data.s "AboutTitle", "About AI Copilot Mapper"
  Data.s "AboutText", "Remaps the Copilot key or your own hotkey to your favorite AI service, a local AI or a system key. Includes an embedded WebView2 browser, custom AI services and per-app profiles."
  Data.s "MsgBoxRunning", "The application is already running (check the system tray)."
  Data.s "CustomAINamePrompt", "Name of the AI service:\nExample: Open WebUI"
  Data.s "CustomAIURLPrompt", "URL to the AI service:\nExample: http://localhost:3000"
  Data.s "CustomAINotCustomTitle", "Custom AI"
  Data.s "CustomAINotCustomMsg", "The selected AI is not a custom AI and cannot be removed."
  Data.s "RegErrorTitle", "Permission Error"
  Data.s "RegErrorMsg", "Windows denied access to Autostart."
  Data.s "ErrorCode", "Error code"
  Data.s "ProfileReloadedTitle", "Profiles"
  Data.s "ProfileReloadedMsg", "Profiles have been reloaded."
  Data.s "ProfileTemplateTitle", "AI Copilot Mapper - per-app profiles"
  Data.s "ProfileTemplateHint", "Set Count to the number of active profiles and fill in the fields below."
  Data.s "HotkeyCurrent", "Active hotkey:"
  Data.s "HotkeyPrompt", "Press your desired key combination now..."
  Data.s "HotkeyWaiting", "Waiting for key press..."
  Data.s "HotkeyCancel", "Cancel"
  Data.s "HotkeyNoModifierWarn", "This key has no Ctrl/Alt/Shift/Win modifier and will be blocked everywhere in Windows.\nUse it anyway?"
  Data.s "CopilotKey", "Copilot key"
  Data.s "KeyCode", "Key code"
  Data.s "HookErrorTitle", "Keyboard hook error"
  Data.s "HookErrorMsg", "Could not install the keyboard hook. The hotkey will not work."
  Data.s "TrayPaused", "Status: Paused"
  Data.s "TrayViewEmbedded", "View: WebView2"
  Data.s "TrayViewExternal", "View: External"
  Data.s "AIWindowTitle", "AI Copilot View"
  Data.s "SettingsTitle", "AI Copilot Mapper - Settings"
  Data.s "FrameHotkey", "Hotkey and Function"
  Data.s "BtnRecord", "Record..."
  Data.s "BtnReset", "Reset"
  Data.s "LabelButtonAction", "Button action:"
  Data.s "FrameAI", "AI Service"
  Data.s "BtnAddCustom", "Add Custom"
  Data.s "BtnRemoveSelected", "Remove Selected"
  Data.s "FrameBrowser", "Browser and Display"
  Data.s "LabelExternalBrowser", "External browser:"
  Data.s "FrameSystem", "System and Profiles"
  Data.s "BtnOpenProfiles", "Open App Profiles (.ini)"
  Data.s "BtnReloadProfiles", "Reload App Profiles"
  Data.s "BtnClose", "Close"
  Data.s "", ""
EndDataSection
; IDE Options = PureBasic 6.40 (Windows - x64)
; CursorPosition = 19
; Folding = ----------
; EnableXP
; DPIAware
; UseIcon = aicopilotmapper.ico
; Executable = ..\AICopilotMapper.exe
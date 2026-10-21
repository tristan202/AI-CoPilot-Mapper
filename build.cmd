@echo off
rem Kompilerer AI Copilot Mapper og bygger installer + portable zip i dist\
setlocal
cd /d "%~dp0"

set "PBC=%ProgramFiles%\PureBasic\Compilers\pbcompiler.exe"
set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
set "PORT=build\portable\AICopilotMapper"

rem Versionen laeses fra #AppVersion i kildekoden, saa den kun skal rettes eet sted
set "VERSION="
for /f "tokens=2 delims==" %%v in ('findstr /b /c:"#AppVersion" aicopilotmapper.pb') do set "VERSION=%%v"
set "VERSION=%VERSION: =%"
set VERSION=%VERSION:"=%
if "%VERSION%"=="" (
  echo Kunne ikke finde #AppVersion i aicopilotmapper.pb.
  exit /b 1
)
echo Bygger AI Copilot Mapper %VERSION%

if not exist build mkdir build
if not exist dist mkdir dist

"%PBC%" aicopilotmapper.pb /XP /DPIAWARE /ICON aicopilotmapper.ico /EXE build\AICopilotMapper.exe
if errorlevel 1 (
  echo Kompilering fejlede.
  exit /b 1
)

"%ISCC%" /Q /DAppVersion=%VERSION% installer.iss
if errorlevel 1 (
  echo Inno Setup fejlede.
  exit /b 1
)

rem Portable: programmet gemmer altid indstillinger ved siden af exe-filen
if exist build\portable rmdir /s /q build\portable
mkdir "%PORT%"
copy /y build\AICopilotMapper.exe "%PORT%\" >nul
copy /y *.lng "%PORT%\" >nul
copy /y AICopilotMapper_profiles.ini "%PORT%\" >nul
if exist "dist\AICopilotMapper-%VERSION%-portable.zip" del "dist\AICopilotMapper-%VERSION%-portable.zip"
tar -a -c -f "dist\AICopilotMapper-%VERSION%-portable.zip" -C build\portable AICopilotMapper
if errorlevel 1 (
  echo Portable zip fejlede.
  exit /b 1
)

echo Installer og portable zip bygget i dist\

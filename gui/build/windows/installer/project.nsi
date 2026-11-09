Unicode true

!define INFO_PROJECTNAME "QingDaoFu"
!define INFO_COMPANYNAME "QingDaoFu"
!define INFO_PRODUCTNAME "清道夫"
!define INFO_PRODUCTVERSION "1.3.1"
!define INFO_COPYRIGHT "MIT License"
!define PRODUCT_EXECUTABLE "QingDaoFu.exe"
!define UNINST_KEY_NAME "QingDaoFu"
!define WAILS_INSTALL_WEBVIEW_DETAILPRINT "正在检查并安装 WebView2 运行库…"
!define WAILS_WIN10_REQUIRED "清道夫仅支持 Windows 10 / Windows 11，请在受支持的系统上安装。"
!define WAILS_ARCHITECTURE_NOT_SUPPORTED "清道夫仅支持 64 位 Windows（x64），当前电脑的架构不受支持。"

!include "wails_tools.nsh"

VIProductVersion "${INFO_PRODUCTVERSION}.0"
VIFileVersion    "${INFO_PRODUCTVERSION}.0"
VIAddVersionKey "CompanyName"      "${INFO_COMPANYNAME}"
VIAddVersionKey "FileDescription"  "清道夫安装程序"
VIAddVersionKey "ProductVersion"   "${INFO_PRODUCTVERSION}"
VIAddVersionKey "FileVersion"      "${INFO_PRODUCTVERSION}"
VIAddVersionKey "LegalCopyright"   "${INFO_COPYRIGHT}"
VIAddVersionKey "ProductName"      "${INFO_PRODUCTNAME}"

ManifestDPIAware true
ManifestSupportedOS Win10

!include "MUI2.nsh"
!define MUI_ICON "..\icon.ico"
!define MUI_UNICON "..\icon.ico"
!define MUI_FINISHPAGE_NOAUTOCLOSE
!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXECUTABLE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动清道夫"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Name "${INFO_PRODUCTNAME}"
OutFile "..\..\bin\QingDaoFu-1.3.1-x64-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\QingDaoFu"
ShowInstDetails show

Function .onInit
    !insertmacro wails.checkArchitecture
FunctionEnd

Section "安装"
    !insertmacro wails.setShellContext
    !insertmacro wails.webview2runtime

    SetOutPath "$INSTDIR"
    !insertmacro wails.files

    ; Wails' default installer copies only the executable. QingDaoFu also needs
    ; its PowerShell core and rules beside the EXE, so ship the same payload as
    ; the portable package.
    SetOutPath "$INSTDIR\app"
    File /r "..\..\payload\app\*.*"
    SetOutPath "$INSTDIR\rules"
    File /r "..\..\payload\rules\*.*"
    SetOutPath "$INSTDIR"
    File "..\..\payload\VERSION"
    File "..\..\payload\README.md"
    File "..\..\payload\RELEASE.md"
    File "..\..\payload\LICENSE"
    File "..\..\payload\THIRD_PARTY_NOTICES.md"
    File "..\..\payload\使用前必读.txt"
    File "..\..\payload\启动清道夫.cmd"

    CreateShortcut "$SMPROGRAMS\清道夫.lnk" "$INSTDIR\${PRODUCT_EXECUTABLE}" "" "$INSTDIR\${PRODUCT_EXECUTABLE}" 0
    CreateShortcut "$DESKTOP\清道夫.lnk" "$INSTDIR\${PRODUCT_EXECUTABLE}" "" "$INSTDIR\${PRODUCT_EXECUTABLE}" 0
    ; Cache the executable icon so Windows does not reuse an old thumbnail.
    !insertmacro wails.writeUninstaller
SectionEnd

Section "Uninstall"
    !insertmacro wails.setShellContext
    RMDir /r "$INSTDIR"
    Delete "$SMPROGRAMS\清道夫.lnk"
    Delete "$DESKTOP\清道夫.lnk"
    !insertmacro wails.deleteUninstaller
SectionEnd

; ---------------------------------------------------------------------------
; FileZilla system light/dark overlay installer
;
; TEMPLATE. build-nsis-installer_win64.ps1 substitutes the @@...@@ tokens and emits the
; per-file backup, copy and restore code from the staged, stripped tree, so the payload has
; exactly one source of truth - the staged overlay that the test suite validates - and
; cannot drift from it.
;
; Syntax and environment traps this file is written around, each of which cost real
; debugging time on this makensis 3.13:
;
;   $NAME        a runtime variable           ($INSTDIR, $Replaced)
;   ${NAME}      a compile-time !define or macro parameter
;   $(NAME)      a LangString lookup - NOT a variable or define reference. It silently
;                expands to nothing and makensis only emits "warning 6040: LangString ... is
;                not set". Writing ${FZ_VERSION} made the version check test a
;                root-relative path, so every install aborted. build-nsis-installer_win64.ps1
;                fails the build on warning 6040.
;
;   FileWrite does not interpret backtick escapes here - "a`nb" is written literally as
;   six characters. So nothing in this installer writes multi-line text.
;
;   FileOpen on a file that was embedded with File into $PLUGINSDIR fails on this build, so
;   there is no runtime file I/O at all: the payload is compiled in as per-file code.
;
;   Loops use ${Do}/${Loop}/${Break}, never Goto. Jumping out of a ${If} block leaves
;   LogicLib's generated labels unresolved and makensis aborts with
;   "could not resolve label _LogicLib_ElseLabel_...".
;
;   FindFirst takes no attributes argument, so directory listings are filtered afterwards
;   rather than by "isdirectory".
;
;   RequestExecutionLevel defaults to admin in this NSIS, so it is stated explicitly.
;
; No plugins are used, and two conveniences are given up for that. StrFunc here has no
; Get/GetParent/Trim, and there is no GetTime. Neither is needed: CopyFiles creates
; intermediate directories, so backups keep the payload's own layout with no path surgery,
; and backup directories are named by an incrementing counter rather than a wall-clock
; stamp. Everything used is core NSIS plus MUI2 and LogicLib.
;
; Behaviour matches the PowerShell installer in the .7z: find the install directory, refuse
; a mismatched FileZilla, back up everything it is about to replace, install, and register
; a removal tool. Undo information is the backup directory itself, so nothing has to be
; parsed at run time - which matters because this NSIS cannot be relied on for runtime file
; I/O.
;
; Removal is a separate, payload-free executable rather than NSIS's built-in uninstaller:
; the uninstaller this makensis produces runs silently and does nothing at all, which was
; measured rather than assumed. See overlay-uninstaller.nsi. This installer copies that
; executable into the FileZilla directory and points Add/Remove Programs at it. The two
; installers are not interchangeable on the same tree: remove an NSIS overlay with the tool
; it installed.
; ---------------------------------------------------------------------------
Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "FileZilla @@FZVERSION@@ - system light/dark overlay"
OutFile "@@OUTFILE@@"

; A Program Files target needs an elevated process. Unconditional elevation means a
; per-user FileZilla under %LOCALAPPDATA% prompts too; the alternative is a runtime
; re-launch guarded by a writable-target check, which is a lot more NSIS for a case few
; users hit. The build substitutes user for test builds, which run unattended against a
; scratch copy and must not be handed a UAC prompt.
RequestExecutionLevel @@ELEVATION@@

; Solid LZMA. makensis 3.13 rejects "SetCompressor /SOLID lzma2" and "/SOLID_LZMA"; this is
; the strongest compressor it accepts. The dictionary size is left at the default because it
; makes no difference here - 16, 32 and 64 MB produced byte-identical output.
SetCompressor /SOLID lzma

!define FZ_VERSION      "@@FZVERSION@@"
!define FZ_VERSION_FILE "@@FZVERSIONFILE@@"
!define BACKUP_DIRNAME  "fzdark-backup"
!define BACKUP_LOGNAME  "installed.txt"
!define PAYLOAD_COUNT   "@@PAYLOAD_COUNT@@"

; Add/Remove Programs. InstallLocation doubles as the record of a directory the user chose
; on the directory page, which is how a later install or the uninstaller finds a
; non-default target without being told.
!define ARP_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FileZillaDarkOverlay"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var Cand
Var Found
Var Plausible
Var TmpA
Var TmpB
Var TmpC
Var TargetDir
Var BackupRoot
Var NewestBackup
Var Stamp
Var Replaced
Var Added
Var Fh

; ====================================================================== refusals

; Stop without touching anything, and say why in a form a person can read.
;
; Abort alone is not enough. Under MUI it lands in the "Installation Aborted" details box,
; which is a scrolled single-line control: a long sentence runs off the right edge and is
; simply clipped. So in interactive mode a real message box is shown first, with hard line
; breaks. Silent mode must never block on a dialog nobody will click, so there the text goes
; to MUI's log and to a file under %TEMP% instead, and the process just exits non-zero.
;
; Newlines are "$\n", not a backtick. A backtick was never an NSIS escape, which is what made
; every message render as one unreadable line.
;
; The log path is named in the message because the exit code cannot be trusted: this
; installer requires elevation, and when the shell has to spawn an elevated child the child's
; exit code does not come back through $LASTEXITCODE - measured, 0 after a refusal that had
; in fact worked. The log is the reliable signal, so every message points at it.
;
; Call as: !insertmacro REFUSE "line one$\n$\nline three"
!macro REFUSE TEXT
  ${IfNot} ${Silent}
    MessageBox MB_ICONSTOP|MB_OK "${TEXT}$\n$\nThe same text was written to$\n$TEMP\fzdark-overlay-setup.log"
  ${EndIf}
  DetailPrint "${TEXT}"
  ClearErrors
  FileOpen $Fh "$TEMP\fzdark-overlay-setup.log" w
  FileWrite $Fh "[${FZ_VERSION}] refused: ${TEXT}$\n"
  FileClose $Fh
  Abort ""
!macroend

; ==================================================================== discovery

; Structural release check: writes 1 into $Found when DIR holds FileZilla @@FZVERSION@@.
; The two client DLL names carry the FileZilla version with dots replaced by dashes, so
; their presence pins the release. Reading a PE version resource instead would need the
; VersionInfo plugin, which this NSIS does not ship.
!macro CHECK_FZ_DIR DIR
  StrCpy $Found 0
  ${If} ${FileExists} "${DIR}\bin\filezilla.exe"
  ${OrIf} ${FileExists} "${DIR}\filezilla.exe"
    ${If} ${FileExists} "${DIR}\libfzclient-private-${FZ_VERSION_FILE}.dll"
    ${AndIf} ${FileExists} "${DIR}\libfzclient-commonui-private-${FZ_VERSION_FILE}.dll"
      StrCpy $Found 1
    ${EndIf}
  ${EndIf}
!macroend

; Refuse to install over an overlay that is already there.
;
; This is the guard that was missing, and its absence produced a support problem no user
; could escape. Installing the overlay twice corrupted the undo chain:
;
;   install 1  backs up the 8 STOCK files into backup-0000
;   install 2  sees all 32 payload files already present, so it backs up all 32 OVERLAY
;              files into backup-0001 as though they were the originals
;   uninstall  restores from the newest backup, i.e. copies the overlay over itself
;              while the true stock files stay buried in backup-0000
;
; The uninstaller then deleted the Add/Remove Programs entry unconditionally, so the user
; was left with dark mode, no entry in Add/Remove, and a removal tool that reported the
; overlay was not installed. Undoing it by hand meant knowing that the originals were
; sitting in a backup folder the tool had stopped looking at.
;
; Two independent signals, either of which is enough. Stock FileZilla has neither:
;
;   1. the Add/Remove Programs key, which survives even if the backup folder is deleted
;   2. the backup FOLDER itself, not just a marker file in it - a half-deleted backup
;      directory is itself proof an install ran here, and is exactly the state a
;      botched removal leaves behind
;
; The PowerShell installer in the .7z adds a third, a payload file whose SHA-256 still
; matches ours, which catches the case where both of these were removed by hand. This
; NSIS cannot hash without a plugin it does not ship, so it uses the two it can read.
;
; Call after the FileZilla version check, so a folder that is not FileZilla is never
; judged on overlay state, and before anything is written.
!macro ASSERT_NOT_ALREADY_INSTALLED
  ReadRegStr $TmpB HKLM "${ARP_KEY}" "InstallLocation"
  ${If} $TmpB != ""
    !insertmacro REFUSE "The dark overlay is already registered in Add/Remove Programs as$\n$\n  FileZilla @@FZVERSION@@ light/dark overlay$\n$\npointing at:$\n  $TmpB$\n$\nInstalling a second time would back up the already-overlaid$\nfiles as if they were the originals, which breaks removal: the$\nuninstaller would restore the overlay over itself and delete the$\nonly Add/Remove entry, leaving dark mode you cannot get rid of.$\n$\nNothing has been changed.$\n$\nRemove the overlay first, from Add/Remove Programs, then run$\nthis installer again."
  ${EndIf}

  ${If} ${FileExists} "$INSTDIR\${BACKUP_DIRNAME}\*.*"
    !insertmacro REFUSE "A backup folder from a previous overlay install is still$\npresent in:$\n  $INSTDIR\${BACKUP_DIRNAME}$\n$\nFileZilla does not create that folder, so an overlay has been$\ninstalled here before. It may or may not still be active.$\n$\nInstalling over it would back up the already-overlaid files as$\nif they were the originals, which breaks removal.$\n$\nNothing has been changed.$\n$\nRun the removal tool (Add/Remove Programs, or$\n%LOCALAPPDATA%\fzdark\@@UNINST_NAME@@ /D=$INSTDIR) to uninstall it$\ncleanly first. If that reports the overlay is not installed but the$\nfolder is still here, reinstall FileZilla from the official package$\nto get a clean copy."
  ${EndIf}
!macroend

; Consider $Cand. Records the first real @@FZVERSION@@ install in $INSTDIR and, separately,
; the first merely plausible FileZilla in $Plausible, so a version mismatch can report what
; it found instead of leaving the directory box empty.
!macro CONSIDER_CAND
  ${If} $Found != 1
    ${If} ${FileExists} "$Cand\bin\filezilla.exe"
    ${OrIf} ${FileExists} "$Cand\filezilla.exe"
      ${If} $Plausible == ""
        StrCpy $Plausible "$Cand"
      ${EndIf}
      !insertmacro CHECK_FZ_DIR "$Cand"
      ${If} $Found == 1
        StrCpy $INSTDIR "$Cand"
      ${EndIf}
    ${EndIf}
  ${EndIf}
!macroend

; Enumerate every FileZilla* entry directly under BASE. Matching on a prefix rather than an
; exact name is what fixes auto-detection: the official build installs to "FileZilla FTP
; Client" and the Store build to "FileZilla 3", while the earlier code looked only for
; "FileZilla" and found neither. "FileZilla Server" is rejected because it holds no
; filezilla.exe.
;
; FileZilla's own uninstall registry key is deliberately not consulted: the client install
; registers no InstallLocation (only "FileZilla Server" carries one), so enumerating three
; registry roots added nothing.
!macro SCAN_BASE BASE
  FindFirst $TmpC $TmpA "${BASE}\FileZilla*"
  ${DoWhile} $TmpA != ""
    StrCpy $Cand "${BASE}\$TmpA"
    !insertmacro CONSIDER_CAND
    FindNext $TmpC $TmpA
  ${Loop}
!macroend

Function .onInit
  ; $INSTDIR arrives empty unless the caller passed /D=. When it is already set that is the
  ; caller's explicit choice - or a test harness pointing at a scratch copy - so detection
  ; must not overwrite it. The install section re-checks whatever ends up here either way.
  ${If} $INSTDIR != ""
    Return
  ${EndIf}

  StrCpy $Found 0
  StrCpy $Plausible ""

  ; A previous run of this installer, possibly into a directory the user chose.
  ReadRegStr $Cand HKLM "${ARP_KEY}" "InstallLocation"
  ${If} $Cand != ""
    !insertmacro CONSIDER_CAND
  ${EndIf}

  !insertmacro SCAN_BASE "$PROGRAMFILES64"
  !insertmacro SCAN_BASE "$PROGRAMFILES32"
  !insertmacro SCAN_BASE "$LOCALAPPDATA"
  !insertmacro SCAN_BASE "$LOCALAPPDATA\Programs"

  ${If} $Found != 1
    ${If} $Plausible != ""
      StrCpy $INSTDIR "$Plausible"
      MessageBox MB_ICONEXCLAMATION|MB_OK "Found FileZilla in:$\r$\n$\r$\n$Plausible$\r$\n$\r$\nbut it does not have the client DLLs for ${FZ_VERSION}, so this overlay cannot be installed over it.$\r$\n$\r$\nPoint the next page at a FileZilla ${FZ_VERSION} installation, or cancel and use the .7z archive with the included PowerShell installer instead."
    ${Else}
      StrCpy $INSTDIR "$PROGRAMFILES64\FileZilla FTP Client"
      MessageBox MB_ICONEXCLAMATION|MB_OK "No FileZilla installation was found.$\r$\n$\r$\nUse the next page to point at the FileZilla folder. It must contain filezilla.exe and the ${FZ_VERSION} client DLLs."
    ${EndIf}
  ${EndIf}
FunctionEnd

; ====================================================================== install

; Fresh backup directory name: backup-0001, backup-0002, ... An existing marker file marks
; a name as taken, so a stray empty directory does not push the counter along.
!macro NEXT_BACKUP_NAME
  IntOp $TmpC 0 + 0
  IntFmt $Stamp "backup-%04d" $TmpC
  ${DoWhile} ${FileExists} "$BackupRoot\$Stamp\${BACKUP_LOGNAME}"
    IntOp $TmpC $TmpC + 1
    IntFmt $Stamp "backup-%04d" $TmpC
  ${Loop}
!macroend

Section "Install"
  ; Note on the log below: this NSIS's FileOpen mode "a" truncates instead of appending, so
  ; a run writes its record exactly once. A refusal records itself; a successful install
  ; records what it did at the end. Writing both would silently lose the first entry.

  ; Check what this folder actually is BEFORE touching it. Doing the writability probe first
  ; meant a folder that is not FileZilla at all still got a temporary file written into it,
  ; which then showed up in the installer's own log as a confusing extra line.
  !insertmacro CHECK_FZ_DIR "$INSTDIR"
  ${If} $Found != 1
    !insertmacro REFUSE "This is not a FileZilla ${FZ_VERSION} installation.$\n$\nFolder:$\n$INSTDIR$\n$\nIt must contain filezilla.exe plus the client DLLs$\nlibfzclient-private-${FZ_VERSION_FILE}.dll and$\nlibfzclient-commonui-private-${FZ_VERSION_FILE}.dll.$\n$\nNothing has been changed. Choose the correct FileZilla$\nfolder on the next page, or cancel and run this on a$\nFileZilla ${FZ_VERSION} installation."
  ${EndIf}

  ; Overlay state, checked before the writability probe so a refusal leaves no trace at
  ; all - not even the probe's temporary file.
  !insertmacro ASSERT_NOT_ALREADY_INSTALLED

  ; Writable target. Only worth checking once the folder is known to be the right one.
  StrCpy $TmpA "$INSTDIR\fzdark-write-probe.tmp"
  ClearErrors
  FileOpen $Fh $TmpA w
  ${If} ${Errors}
    !insertmacro REFUSE "Cannot write to:$\n$INSTDIR$\n$\nInstalling into Program Files needs an elevated$\ninstaller: right-click this file and Run as administrator.$\nOr choose a FileZilla installed somewhere writable.$\n$\nNothing has been changed."
  ${EndIf}
  FileClose $Fh
  Delete $TmpA

  ; Locked-file detection happens per payload file, in the backup loop below, by opening each
  ; existing target for append and closing it again without writing. See the comment there for
  ; why that and not something cruder. It has to run after the version check, so a folder that
  ; is not FileZilla is never touched at all.

  StrCpy $TargetDir "$INSTDIR"
  StrCpy $BackupRoot "$INSTDIR\${BACKUP_DIRNAME}"
  !insertmacro NEXT_BACKUP_NAME
  StrCpy $NewestBackup "$BackupRoot\$Stamp"

  ; Locked-file detection, before anything at all is created. If a FileZilla from this folder
  ; is running, the payload files it has loaded cannot be written, and the install has to stop
  ; here rather than part way through with a half-written overlay.
@@PROBE_BEGIN@@

  ; Classify and back up everything that is about to be replaced BEFORE writing any of it, so
  ; an install that fails later can still be undone from this directory alone.
  ClearErrors
  CreateDirectory "$NewestBackup"
  ${If} ${Errors}
    !insertmacro REFUSE "Could not create the backup folder:$\n$NewestBackup$\n$\nCheck that $INSTDIR is writable.$\n$\nNothing has been changed."
  ${EndIf}

  ; Marker file: what makes this directory recognisable as a backup during uninstall. One
  ; line only, because FileWrite does not expand backtick escapes on this build.
  FileOpen $Fh "$NewestBackup\${BACKUP_LOGNAME}" w
  FileWrite $Fh "fzdark dark overlay backup for FileZilla ${FZ_VERSION} in $TargetDir"
  FileClose $Fh

  IntOp $Replaced 0 + 0
  IntOp $Added 0 + 0

@@BACKUP_BEGIN@@

  ; Now write the payload, grouped by destination directory.
@@PAYLOAD_BEGIN@@

; The removal tool is a separate, payload-free executable: this NSIS's own uninstaller
  ; runs silently and does nothing (see overlay-uninstaller.nsi for the measurements), so an
  ; ordinary installer is used as the removal tool instead.
  ;
  ; It goes to %LOCALAPPDATA%\fzdark, not into the FileZilla directory, because a running
  ; executable cannot delete itself: leaving it inside FileZilla would mean the installation
  ; could never be restored byte-for-byte.
  CreateDirectory "$LOCALAPPDATA\fzdark"
  SetOutPath "$LOCALAPPDATA\fzdark"
  File "@@UNINST_EXE@@"

  WriteRegStr HKLM "${ARP_KEY}" "DisplayName"     "FileZilla ${FZ_VERSION} light/dark overlay"
  WriteRegStr HKLM "${ARP_KEY}" "DisplayVersion"  "${FZ_VERSION}"
  WriteRegStr HKLM "${ARP_KEY}" "Publisher"       "FileZilla dark theme kit"
  WriteRegStr HKLM "${ARP_KEY}" "DisplayIcon"     "$INSTDIR\filezilla.exe"
  WriteRegStr HKLM "${ARP_KEY}" "InstallLocation" "$TargetDir"
  WriteRegStr HKLM "${ARP_KEY}" "UninstallString" '"$LOCALAPPDATA\fzdark\@@UNINST_NAME@@" /S /D=$INSTDIR'
  WriteRegDWORD HKLM "${ARP_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${ARP_KEY}" "NoRepair" 1

  DetailPrint "Installed ${PAYLOAD_COUNT} overlay files into $TargetDir"
  DetailPrint "Replaced $Replaced, added $Added"
  DetailPrint "Backup kept at $NewestBackup"
  DetailPrint "To remove: Add/Remove Programs, or run %LOCALAPPDATA%\fzdark\@@UNINST_NAME@@ /S /D=$INSTDIR"

  ; The one record this run writes. Mode "w" is explicit because "a" truncates on this NSIS,
  ; so nothing may rely on it preserving an earlier entry.
  ClearErrors
  FileOpen $Fh "$TEMP\fzdark-overlay-setup.log" w
  FileWrite $Fh "[${FZ_VERSION}] installed into $TargetDir$\n  replaced $Replaced, added $Added$\n  backup kept at $NewestBackup$\n"
  FileClose $Fh
SectionEnd


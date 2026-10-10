; ---------------------------------------------------------------------------
; FileZilla dark overlay - uninstaller
;
; TEMPLATE. build-nsis-installer_win64.ps1 substitutes the @@...@@ tokens and the per-file
; restore code, then compiles this into a small payload-free executable (~54 KB). The
; installer copies it to %LOCALAPPDATA%\fzdark - deliberately NOT into the FileZilla
; directory - and points Add/Remove Programs at it there.
;
; Why a second executable instead of NSIS's built-in uninstaller
; -----------------------------------------------------------
; WriteUninstaller was tried first and is the conventional choice, but the uninstaller this
; makensis produces does not reliably run: uninstalling with /S exited 0 having done nothing
; at all - not even deleting itself - and the same happened with no arguments. It only ran
; when passed /NCRC. That is not something to ship, and the failure is silent: Add/Remove
; Programs would appear to work while leaving the overlay in place.
;
; This distribution is already non-standard in ways that were measured rather than assumed:
; a reduced StrFunc.nsh with no Get/GetParent/Trim, no GetTime, FileWrite expanding no
; backtick escapes, a literal double quote impossible inside a string, FindFirst without an
; attributes argument, Delete /REBOOTOK doing nothing, and RequestExecutionLevel defaulting
; to admin. Ordinary installers work reliably on it, so the restore is an ordinary installer
; here.
;
; Why it lives outside the FileZilla directory
; --------------------------------------------
; A running executable cannot delete itself, and a sibling copy cannot delete it either while
; it runs - so a self-removing uninstaller placed in the FileZilla directory always leaves
; something behind. Delete /REBOOTOK is not available to clean that up, and a cmd/deferred
; delete is not either, because the batch file would need quoted paths and this NSIS cannot
; put a double quote inside a string. Putting the tool in %LOCALAPPDATA%\fzdark instead means
; a FileZilla installation is left byte-for-byte as it was found, and the only residue is
; this ~54 KB file in our own folder, which the user may delete at any time.
;
; As with the installer: $NAME is a variable, ${NAME} is a define or macro parameter, and
; $(NAME) is a LangString lookup that silently expands to nothing.
; ---------------------------------------------------------------------------
Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "FileZilla @@FZVERSION@@ - remove light/dark overlay"
OutFile "@@UNINST_OUTFILE@@"
RequestExecutionLevel @@ELEVATION@@

!define FZ_VERSION "@@FZVERSION@@"
!define BACKUP_DIRNAME "fzdark-backup"
!define BACKUP_LOGNAME "installed.txt"
!define ARP_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FileZillaDarkOverlay"

!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var TargetDir
Var BackupRoot
Var NewestBackup
Var Replaced
Var Added
Var TmpA
Var TmpB

Section "Remove overlay"
  IntOp $Replaced 0 + 0
  IntOp $Added 0 + 0

  ; The FileZilla directory is passed with /D, so the ARP entry keeps working even if the
  ; tool is run by hand.
  StrCpy $TargetDir "$INSTDIR"
  StrCpy $BackupRoot "$TargetDir\${BACKUP_DIRNAME}"

  ; Newest backup, chosen the same way the installer chooses one: lexical order is
  ; chronological order, and only a directory holding the marker file counts as a backup.
  StrCpy $NewestBackup ""
  FindFirst $TmpA $TmpB "$BackupRoot\*"
  ${DoWhile} $TmpB != ""
    ${If} ${FileExists} "$BackupRoot\$TmpB\${BACKUP_LOGNAME}"
      StrCpy $NewestBackup "$BackupRoot\$TmpB"
    ${EndIf}
    FindNext $TmpA $TmpB
  ${Loop}

  DeleteRegKey HKLM "${ARP_KEY}"

  ${If} $NewestBackup != ""
@@RESTORE_BEGIN@@
    DetailPrint "Restored $Replaced file(s), removed $Added overlay-only file(s) from $TargetDir."
    RMDir /r "$NewestBackup"
  ${Else}
    DetailPrint "No overlay backup was found under $BackupRoot, so no file was restored."
    DetailPrint "Check the overlay archive's manifest for the file list before deleting anything by hand."
  ${EndIf}

  RMDir "$BackupRoot"

  ; The icon directory pre-dates the overlay, so it is only removed when empty.
  RMDir "$TargetDir\resources\default\480x480"
  RMDir "$TargetDir\resources\default"
  RMDir "$TargetDir\resources"
SectionEnd
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
!define PS1_LOGNAME "backup-manifest.txt"
!define ARP_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FileZillaDarkOverlay"

!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var TargetDir
Var BackupRoot
Var OldestBackup
Var BackupCount
Var Replaced
Var Added
Var TmpA
Var TmpB

Section "Remove overlay"
  IntOp $Replaced 0 + 0
  IntOp $Added 0 + 0
  IntOp $BackupCount 0 + 0

  ; The FileZilla directory is passed with /D, so the ARP entry keeps working even if the
  ; tool is run by hand.
  StrCpy $TargetDir "$INSTDIR"
  StrCpy $BackupRoot "$TargetDir\${BACKUP_DIRNAME}"

  ; Choose the OLDEST backup, and count them all.
  ;
  ; This used to take the newest, which is what broke a tree that had been installed
  ; twice: the newest backup then held the overlay itself, so the restore copied the
  ; overlay over itself and the genuine originals stayed buried in the older directory
  ; that nothing pointed at any more. Oldest first is the only order that recovers such
  ; a tree, and for a correctly installed one there is a single backup, so it changes
  ; nothing there.
  ;
  ; FindFirst does not promise sorted order, so the minimum is selected explicitly rather
  ; than by keeping the last match. LogicLib compares operands as strings when they are
  ; not integers, which is what makes 'backup-0000' order correctly against a timestamped
  ; directory from the PowerShell installer.
  ;
  ; Both markers are accepted. This kit writes backup-manifest.txt and the installer
  ; writes installed.txt, so a user who tried one and then the other leaves both kinds,
  ; and recognising only one silently ignored a real backup holding the only copy of
  ; their originals.
  ; Both loops below enumerate $BackupRoot, and FindFirst on this NSIS returns "." and
  ; ".." alongside the real entries - measured, not assumed. The selection loop tolerates
  ; them because the marker test simply fails for them, but the cleanup loop used to do
  ; RMDir /r "$BackupRoot\$TmpB" with no test at all, which meant:
  ;
  ;   RMDir /r "...\fzdark-backup\."    deleted the backup directory
  ;   RMDir /r "...\fzdark-backup\.."   deleted the whole FileZilla directory
  ;
  ; so removal restored the files correctly and then deleted everything anyway. Every
  ; entry is now skipped unless it is a directory carrying one of this kit's own backup
  ; markers, which no parent directory ever has.
  StrCpy $OldestBackup ""
  FindFirst $TmpA $TmpB "$BackupRoot\*"
  ${DoWhile} $TmpB != ""
    ${If} $TmpB != "."
    ${AndIf} $TmpB != ".."
      ${If} ${FileExists} "$BackupRoot\$TmpB\${BACKUP_LOGNAME}"
      ${OrIf} ${FileExists} "$BackupRoot\$TmpB\${PS1_LOGNAME}"
        IntOp $BackupCount $BackupCount + 1
        ${If} $OldestBackup == ""
        ${OrIf} $TmpB < $OldestBackup
          StrCpy $OldestBackup "$TmpB"
        ${EndIf}
      ${EndIf}
    ${EndIf}
    FindNext $TmpA $TmpB
  ${Loop}
  ${If} $OldestBackup != ""
    StrCpy $OldestBackup "$BackupRoot\$OldestBackup"
  ${EndIf}

  ${If} $BackupCount > 1
    DetailPrint "Found $BackupCount overlapping backups; restoring from the oldest."
  ${EndIf}

  ${If} $OldestBackup != ""
@@RESTORE_BEGIN@@
    DetailPrint "Restored $Replaced file(s), removed $Added overlay-only file(s) from $TargetDir."
  ${Else}
    DetailPrint "No overlay backup was found under $BackupRoot, so no file was restored."
    DetailPrint "Overlay files may still be in place: without a backup there is no way to"
    DetailPrint "tell which ones are ours, so nothing has been deleted."
    DetailPrint "Reinstall FileZilla from the official package to get a clean copy."
  ${EndIf}

  ; Every backup goes, not just the one restored from. A leftover backup folder in a
  ; FileZilla installation is residue the user should not have to know to delete, and
  ; leaving one behind is what made a later install pick up a stale undo chain.
  ;
  ; The marker test is the safety interlock, not decoration. Without it this loop
  ; recursively deletes "." and ".." as well as the backups, and ".." is the FileZilla
  ; directory - which is exactly the bug this test now guards against. Only a directory
  ; holding one of our own manifests is ever a backup, so nothing else is reachable.
  FindFirst $TmpA $TmpB "$BackupRoot\*"
  ${DoWhile} $TmpB != ""
    ${If} $TmpB != "."
    ${AndIf} $TmpB != ".."
    ${If} ${FileExists} "$BackupRoot\$TmpB\${BACKUP_LOGNAME}"
    ${OrIf} ${FileExists} "$BackupRoot\$TmpB\${PS1_LOGNAME}"
      RMDir /r "$BackupRoot\$TmpB"
    ${EndIf}
    ${EndIf}
    FindNext $TmpA $TmpB
  ${Loop}
  RMDir "$BackupRoot"

  ; The Add/Remove entry is removed ONLY when a restore actually ran. Deleting it
  ; unconditionally is what turned a failed removal into an unrecoverable one: the user
  ; lost the only entry point in Add/Remove while the overlay stayed installed, and the
  ; leftover tool then reported there was nothing to remove.
  ${If} $OldestBackup != ""
    DeleteRegKey HKLM "${ARP_KEY}"
  ${Else}
    DetailPrint "Keeping the Add/Remove Programs entry, because nothing was restored."
    DetailPrint "Fix the problem above and run this tool again."
  ${EndIf}

  ; The icon directory pre-dates the overlay, so it is only removed when empty.
  RMDir "$TargetDir\resources\default\480x480"
  RMDir "$TargetDir\resources\default"
  RMDir "$TargetDir\resources"
SectionEnd
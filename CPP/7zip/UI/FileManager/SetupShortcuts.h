// SetupShortcuts.h
//
// The self-extracting package cannot run anything after unpacking: the stub that ships with
// 7-Zip (7z.sfx) does not read an SFX configuration at all - measured, RunProgram and
// InstallPath are ignored. So the convenient part of "installing" - a Start Menu shortcut,
// a desktop shortcut and an entry in "Apps & features" - is done by the program itself on
// its first start, after asking. Everything is written under HKEY_CURRENT_USER; no
// administrator rights are involved and "no" loses nothing.

#ifndef ZIP7_INC_SETUP_SHORTCUTS_H
#define ZIP7_INC_SETUP_SHORTCUTS_H

#include "../../../Common/MyString.h"

/* Asks once whether the shortcuts and the uninstall entry should be created, and does it
   when the answer is yes. Does nothing on the second start: the answer is remembered in the
   registry, so the question never comes back (a "no" is an answer too).
   parent is the main window; only 7zFM.exe calls this, never 7zG.exe - 7zG is started for a
   single archive operation and must not ask questions about setup. */
void SetupShortcuts_AskIfNeeded(HWND parent);

#endif

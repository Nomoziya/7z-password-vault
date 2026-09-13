// PasswordVaultUi.h

#ifndef ZIP7_INC_PASSWORD_VAULT_UI_H
#define ZIP7_INC_PASSWORD_VAULT_UI_H

#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/Edit.h"

#include "PasswordVault.h"

/* Shared behaviour for every dialog that has a password field (the extract
   password dialog and the add-to-archive dialog):

     - the saved-passwords window
     - the new-password window
     - typing a saved name to fill in its password
     - offering to store a password that is not in the vault yet

   The two dialogs only differ in their layout, so everything below is written
   against an arbitrary NWindows::NControl::CEdit. */

/* Timer used to wait for a typing pause before a saved name is filled in.
   Filling while the user is still typing broke passwords that happen to start
   with a saved name: typing "cspass" passes through the exact text "cs" and the
   stored password for "cs" replaced what the user had typed so far. */
static const UINT kPasswordVaultAutoTypeTimer = 0x7A01;
static const UINT kPasswordVaultAutoTypeDelayMs = 600;

class CPasswordVaultUi
{
  CPasswordVault _vault;
  bool _loaded;

  bool _closeAfterFill;
  bool _autoTypeByName;
  bool _promptToSaveNew;

  /* The text that was current when the timer was started, and the text whose
     name was already filled in (so the same name is not offered twice). */
  UString _pendingText;
  UString _lastFilledName;

  /* Second password field to keep in sync: the add-to-archive dialog asks for
     the password twice, so filling only the first would make the two fields
     disagree. */
  NWindows::NControl::CEdit *_syncEdit;

  /* Set while the code itself writes to the edit, so the resulting EN_CHANGE
     does not look like typing. */
  bool _selfChange;

  void ReadSettings();
  bool AddOrUpdate(HWND parent, const UString &name, const UString &password);

  /* Writes "password" into the edit without looking like user typing, keeping
     the sync edit in step. */
  void SetEditPassword(NWindows::NControl::CEdit &edit, const UString &password);

public:
  CPasswordVaultUi();
  ~CPasswordVaultUi();

  /* Loads the settings and the vault; a broken vault is reported to the user. */
  void Load(HWND parent);

  /* Keeps this edit in step with every password the vault fills in. */
  void SetSyncEdit(NWindows::NControl::CEdit *edit) { _syncEdit = edit; }

  /* Typing support. Call ScheduleAutoType from EN_CHANGE; the dialog must then
     forward WM_TIMER to OnTimer. */
  void ScheduleAutoType(HWND parent, NWindows::NControl::CEdit &edit);
  bool OnTimer(HWND parent, WPARAM timerID, NWindows::NControl::CEdit &edit);

  /* The saved-passwords window. Returns true when the user filled a password
     in (the window may have closed itself). */
  bool ShowList(HWND parent, NWindows::NControl::CEdit &edit);

  /* The new-password window: adds an entry, or updates the entry of that name.
     When "edit" is given, the stored password is written into it, so the dialog
     continues with the password the user just saved. */
  void CreateNew(HWND parent, NWindows::NControl::CEdit *edit);

  /* Offers to store a password that is not in the vault yet. */
  void OfferToSave(HWND parent, const UString &password);
};



#endif

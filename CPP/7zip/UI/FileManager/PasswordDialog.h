// PasswordDialog.h

#ifndef ZIP7_INC_PASSWORD_DIALOG_H
#define ZIP7_INC_PASSWORD_DIALOG_H

#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/Edit.h"

#include "PasswordDialogRes.h"
#include "PasswordVault.h"

/* "new password" / "edit password" dialog: one name (optional) + one password. */
class CPasswordEditDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _nameEdit;
  NWindows::NControl::CEdit _valueEdit;
  bool _isNew;

  virtual bool OnInit() Z7_override;
  virtual void OnOK() Z7_override;
public:
  UString Name;
  UString Value;

  CPasswordEditDialog(bool isNew): _isNew(isNew) {}
  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD_EDIT, parentWindow); }
};

class CPasswordDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _passwordEdit;
  CPasswordVault _vault;

  /* Re-entrancy guard: SetTextSpec() changes the edit text, which generates
     EN_CHANGE; that must not be treated as the user typing a name. */
  bool _typingGuard;
  UString _lastPromptedName;

  virtual void OnOK() Z7_override;
  virtual bool OnInit() Z7_override;
  virtual bool OnCommand(unsigned code, unsigned itemID, LPARAM lParam) Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;

  void SetTextSpec();
  void ReadControls();
  void OnPasswordTextChanged();
  void ShowSavedPasswords();
  void CreateNewPassword();
  void MaybeOfferToSave();
public:
  UString Password;
  bool ShowPassword;

  CPasswordDialog(): _typingGuard(false), ShowPassword(false) {}
  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD, parentWindow); }
};

/* Unique placeholder name used when the user leaves the name empty. */
UString PasswordVault_MakeDefaultName(const CPasswordVault &vault);

#endif

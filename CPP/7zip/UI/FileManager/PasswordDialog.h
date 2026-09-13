// PasswordDialog.h

#ifndef ZIP7_INC_PASSWORD_DIALOG_H
#define ZIP7_INC_PASSWORD_DIALOG_H

#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/Edit.h"

#include "PasswordDialogRes.h"
#include "PasswordVault.h"
#include "PasswordVaultUi.h"

/* "new password" / "edit password" dialog: one name (optional) + one password.
   When it was opened for a stored entry it also offers to delete that entry. */
class CPasswordEditDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _nameEdit;
  NWindows::NControl::CEdit _valueEdit;
  bool _isNew;

  virtual bool OnInit() Z7_override;
  virtual void OnOK() Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;
public:
  UString Name;
  UString Value;
  /* Set when the user asked to delete the entry instead of saving it. */
  bool Deleted;

  CPasswordEditDialog(bool isNew): _isNew(isNew), Deleted(false) {}
  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD_EDIT, parentWindow); }
};

class CPasswordDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _passwordEdit;
  CPasswordVaultUi _vaultUi;

  virtual void OnOK() Z7_override;
  virtual bool OnInit() Z7_override;
  virtual bool OnCommand(unsigned code, unsigned itemID, LPARAM lParam) Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;
  virtual bool OnTimer(WPARAM timerID, LPARAM lParam) Z7_override;

  void SetTextSpec();
  void ReadControls();
public:
  UString Password;
  bool ShowPassword;

  CPasswordDialog(): ShowPassword(false) {}
  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD, parentWindow); }
};

#endif

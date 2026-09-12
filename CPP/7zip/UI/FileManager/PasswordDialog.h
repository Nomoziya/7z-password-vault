// PasswordDialog.h

#ifndef ZIP7_INC_PASSWORD_DIALOG_H
#define ZIP7_INC_PASSWORD_DIALOG_H

#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/Edit.h"
#include "../../../Windows/Control/ComboBox.h"

#include "PasswordDialogRes.h"
#include "PasswordVault.h"

class CPasswordDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _passwordEdit;
  NWindows::NControl::CComboBox _savedCombo;
  CPasswordVault _vault;

  virtual void OnOK() Z7_override;
  virtual bool OnInit() Z7_override;
  virtual bool OnCommand(unsigned code, unsigned itemID, LPARAM lParam) Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;

  void SetTextSpec();
  void ReadControls();
  void FillSavedCombo();
  void OnSavedSelectionChanged();
  void SaveCurrentPassword();
  void DeleteSelectedSavedPassword();
public:
  UString Password;
  bool ShowPassword;
  
  CPasswordDialog(): ShowPassword(false) {}
  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD, parentWindow); }
};

class CPasswordNameDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _edit;

  virtual bool OnInit() Z7_override;
  virtual void OnOK() Z7_override;
public:
  UString Name;

  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD_NAME, parentWindow); }
};

#endif

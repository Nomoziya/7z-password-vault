// PasswordDialog.cpp

#include "StdAfx.h"

#include "PasswordDialog.h"

#include "../Common/ZipRegistry.h"

#include "PasswordListDialog.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#ifdef Z7_LANG
static const UInt32 kLangIDs[] =
{
  IDT_PASSWORD_ENTER,
  IDX_PASSWORD_SHOW,
  IDB_PASSWORD_LIST,
  IDB_PASSWORD_NEW
};

static const UInt32 kEditDialogLangIDs[] =
{
  IDT_PASSWORD_NAME,
  IDT_PASSWORD_VALUE,
  IDB_PASSWORD_DELETE
};
#endif

// ---- CPasswordEditDialog ----

bool CPasswordEditDialog::OnInit()
{
  #ifdef Z7_LANG
  LangSetWindowText(*this, _isNew ? IDD_PASSWORD_EDIT : IDD_PASSWORD_EDIT_TITLE);
  LangSetDlgItems(*this, kEditDialogLangIDs, Z7_ARRAY_SIZE(kEditDialogLangIDs));
  #endif

  _nameEdit.Attach(GetItem(IDE_PASSWORD_NAME));
  _valueEdit.Attach(GetItem(IDE_PASSWORD_VALUE));
  _nameEdit.SetText(Name);
  _valueEdit.SetText(Value);
  /* Deleting is only offered for an entry that is already stored. */
  ShowItem_Bool(IDB_PASSWORD_DELETE, !_isNew);
  return CModalDialog::OnInit();
}

void CPasswordEditDialog::OnOK()
{
  _nameEdit.GetText(Name);
  _valueEdit.GetText(Value);
  CModalDialog::OnOK();
}

bool CPasswordEditDialog::OnButtonClicked(unsigned buttonID, HWND buttonHWND)
{
  if (buttonID == IDB_PASSWORD_DELETE)
  {
    UString message = PasswordVault_GetText(IDT_PASSWORD_LIST_DELETE_Q, L"");
    if (!Name.IsEmpty())
    {
      message += L"\r\n\r\n";
      message += Name;
    }
    if (::MessageBoxW(*this, message, PasswordVault_GetCaption(),
        MB_ICONQUESTION | MB_YESNO) == IDYES)
    {
      Deleted = true;
      End(IDOK);
    }
    return true;
  }
  return CModalDialog::OnButtonClicked(buttonID, buttonHWND);
}

// ---- CPasswordDialog ----

void CPasswordDialog::ReadControls()
{
  _passwordEdit.GetText(Password);
  ShowPassword = IsButtonCheckedBool(IDX_PASSWORD_SHOW);
}

void CPasswordDialog::SetTextSpec()
{
  _passwordEdit.SetPasswordChar(ShowPassword ? 0 : TEXT('*'));
  _passwordEdit.SetText(Password);
}

bool CPasswordDialog::OnInit()
{
  #ifdef Z7_LANG
  LangSetWindowText(*this, IDD_PASSWORD);
  LangSetDlgItems(*this, kLangIDs, Z7_ARRAY_SIZE(kLangIDs));
  #endif

  _passwordEdit.Attach(GetItem(IDE_PASSWORD_PASSWORD));

  _vaultUi.Load(*this);

  CheckButton(IDX_PASSWORD_SHOW, ShowPassword);
  SetTextSpec();
  return CModalDialog::OnInit();
}

bool CPasswordDialog::OnCommand(unsigned code, unsigned itemID, LPARAM lParam)
{
  if (code == EN_CHANGE && itemID == IDE_PASSWORD_PASSWORD)
  {
    _vaultUi.ScheduleAutoType(*this, _passwordEdit);
    return true;
  }
  return CDialog::OnCommand(code, itemID, lParam);
}

bool CPasswordDialog::OnTimer(WPARAM timerID, LPARAM lParam)
{
  if (_vaultUi.OnTimer(*this, timerID, _passwordEdit))
    return true;
  return CModalDialog::OnTimer(timerID, lParam);
}

bool CPasswordDialog::OnButtonClicked(unsigned buttonID, HWND buttonHWND)
{
  switch (buttonID)
  {
    case IDX_PASSWORD_SHOW:
      ReadControls();
      SetTextSpec();
      return true;
    case IDB_PASSWORD_LIST:
      ReadControls();
      if (_vaultUi.ShowList(*this, _passwordEdit))
      {
        /* The list window wrote into the edit box; read it back so the OK path
           uses what the user picked. */
        _passwordEdit.GetText(Password);
      }
      return true;
    case IDB_PASSWORD_NEW:
      ReadControls();
      _vaultUi.CreateNew(*this, &_passwordEdit);
      /* Whatever was just stored becomes the password of this dialog. */
      _passwordEdit.GetText(Password);
      return true;
  }
  return CDialog::OnButtonClicked(buttonID, buttonHWND);
}

void CPasswordDialog::OnOK()
{
  ReadControls();
  _vaultUi.OfferToSave(*this, Password);
  CModalDialog::OnOK();
}

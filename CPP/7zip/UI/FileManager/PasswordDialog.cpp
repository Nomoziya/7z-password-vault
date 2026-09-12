// PasswordDialog.cpp

#include "StdAfx.h"

#include "PasswordDialog.h"

#include "../Common/ZipRegistry.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#ifdef Z7_LANG
static const UInt32 kLangIDs[] =
{
  IDT_PASSWORD_ENTER,
  IDX_PASSWORD_SHOW,
  IDT_PASSWORD_SAVED,
  IDB_PASSWORD_SAVE,
  IDB_PASSWORD_DELETE
};

static const UInt32 kNameDialogLangIDs[] =
{
  IDT_PASSWORD_NAME
};
#endif

static void VaultErrorMessage(HWND wnd, const UString &message)
{
  // An empty message means the user cancelled a master-password prompt,
  // which is not an error worth reporting.
  if (message.IsEmpty())
    return;
  ::MessageBoxW(wnd, message, L"7-Zip 密码管家", MB_ICONERROR | MB_OK);
}

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

void CPasswordDialog::FillSavedCombo()
{
  _savedCombo.ResetContent();
  const CObjectVector<CPasswordVaultEntry> &entries = _vault.Entries();
  FOR_VECTOR(i, entries)
    _savedCombo.AddString(entries[i].Name);
}

void CPasswordDialog::OnSavedSelectionChanged()
{
  const int index = _savedCombo.GetCurSel();
  if (index < 0)
    return;

  const CObjectVector<CPasswordVaultEntry> &entries = _vault.Entries();
  if ((unsigned)index >= entries.Size())
    return;

  Password = entries[index].Password;
  SetTextSpec();
}

void CPasswordDialog::SaveCurrentPassword()
{
  _passwordEdit.GetText(Password);
  if (Password.IsEmpty())
  {
    ::MessageBoxW(*this, L"密码为空。", L"7-Zip 密码管家", MB_ICONWARNING | MB_OK);
    return;
  }

  CPasswordNameDialog nameDialog;
  if (nameDialog.Create(*this) != IDOK)
    return;

  UString name = nameDialog.Name;
  name.Trim();
  if (name.IsEmpty())
  {
    ::MessageBoxW(*this, L"名称为空。", L"7-Zip 密码管家", MB_ICONWARNING | MB_OK);
    return;
  }

  int index = _vault.FindByName(name);
  if (index >= 0)
  {
    UString message = L"已存在名为“";
    message += name;
    message += L"”的密码，是否覆盖？";
    if (::MessageBoxW(*this, message, L"7-Zip 密码管家", MB_ICONQUESTION | MB_YESNO) != IDYES)
      return;
    _vault.Entries()[(unsigned)index].Password = Password;
  }
  else
  {
    CPasswordVaultEntry entry;
    entry.Name = name;
    entry.Password = Password;
    _vault.Entries().Add(entry);
  }

  UString error;
  if (!_vault.Save(error))
  {
    VaultErrorMessage(*this, error);
    return;
  }

  FillSavedCombo();
  index = _vault.FindByName(name);
  if (index >= 0)
    _savedCombo.SetCurSel((unsigned)index);
}

void CPasswordDialog::DeleteSelectedSavedPassword()
{
  const int index = _savedCombo.GetCurSel();
  if (index < 0)
    return;

  const CObjectVector<CPasswordVaultEntry> &entries = _vault.Entries();
  if ((unsigned)index >= entries.Size())
    return;

  UString message = L"删除已保存的密码“";
  message += entries[index].Name;
  message += L"”？";
  if (::MessageBoxW(*this, message, L"7-Zip 密码管家", MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  _vault.Entries().Delete((unsigned)index);

  UString error;
  if (!_vault.Save(error))
    VaultErrorMessage(*this, error);

  FillSavedCombo();
}

bool CPasswordDialog::OnInit()
{
  #ifdef Z7_LANG
  LangSetWindowText(*this, IDD_PASSWORD);
  LangSetDlgItems(*this, kLangIDs, Z7_ARRAY_SIZE(kLangIDs));
  #endif

  _passwordEdit.Attach(GetItem(IDE_PASSWORD_PASSWORD));
  _savedCombo.Attach(GetItem(IDE_PASSWORD_SAVED));

  _vault.SetPath(CPasswordVault::GetConfiguredPath());
  UString error;
  if (!_vault.Load(*this, error))
    VaultErrorMessage(*this, error);
  FillSavedCombo();

  NPasswordVault::CInfo settings;
  settings.Load();

  // Auto-fill the only saved password when enabled.
  // Don't overwrite a password that the caller already put into the dialog.
  if (settings.AutoFill && Password.IsEmpty() && _vault.Entries().Size() == 1)
  {
    _savedCombo.SetCurSel(0);
    Password = _vault.Entries()[0].Password;
  }

  CheckButton(IDX_PASSWORD_SHOW, ShowPassword);
  SetTextSpec();
  return CModalDialog::OnInit();
}

bool CPasswordDialog::OnCommand(unsigned code, unsigned itemID, LPARAM lParam)
{
  if (code == CBN_SELCHANGE && itemID == IDE_PASSWORD_SAVED)
  {
    OnSavedSelectionChanged();
    return true;
  }
  return CDialog::OnCommand(code, itemID, lParam);
}

bool CPasswordDialog::OnButtonClicked(unsigned buttonID, HWND buttonHWND)
{
  switch (buttonID)
  {
    case IDX_PASSWORD_SHOW:
      ReadControls();
      SetTextSpec();
      return true;
    case IDB_PASSWORD_SAVE:
      SaveCurrentPassword();
      return true;
    case IDB_PASSWORD_DELETE:
      DeleteSelectedSavedPassword();
      return true;
  }
  return CDialog::OnButtonClicked(buttonID, buttonHWND);
}

void CPasswordDialog::OnOK()
{
  ReadControls();
  CModalDialog::OnOK();
}

// ---- CPasswordNameDialog ----

bool CPasswordNameDialog::OnInit()
{
  #ifdef Z7_LANG
  LangSetWindowText(*this, IDD_PASSWORD_NAME);
  LangSetDlgItems(*this, kNameDialogLangIDs, Z7_ARRAY_SIZE(kNameDialogLangIDs));
  #endif
  _edit.Attach(GetItem(IDE_PASSWORD_NAME));
  _edit.SetText(Name);
  return CModalDialog::OnInit();
}

void CPasswordNameDialog::OnOK()
{
  _edit.GetText(Name);
  CModalDialog::OnOK();
}

// PasswordDialog.cpp

#include "StdAfx.h"

#include "PasswordDialog.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#ifdef Z7_LANG
static const UInt32 kLangIDs[] =
{
  IDT_PASSWORD_ENTER,
  IDX_PASSWORD_SHOW
};
#endif

static void VaultErrorMessage(HWND wnd, const UString &message)
{
  ::MessageBoxW(wnd, message, L"7-Zip Password Vault", MB_ICONERROR | MB_OK);
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

  UString decrypted;
  UString error;
  if (!CPasswordVault::DecryptPassword(entries[index].EncryptedPassword, decrypted, error))
  {
    VaultErrorMessage(*this, error);
    return;
  }

  Password = decrypted;
  SetTextSpec();
}

void CPasswordDialog::SaveCurrentPassword()
{
  _passwordEdit.GetText(Password);
  if (Password.IsEmpty())
  {
    ::MessageBoxW(*this, L"Password is empty.", L"7-Zip Password Vault", MB_ICONWARNING | MB_OK);
    return;
  }

  CPasswordNameDialog nameDialog;
  if (nameDialog.Create(*this) != IDOK)
    return;

  UString name = nameDialog.Name;
  name.Trim();
  if (name.IsEmpty())
  {
    ::MessageBoxW(*this, L"Name is empty.", L"7-Zip Password Vault", MB_ICONWARNING | MB_OK);
    return;
  }

  UString error;
  CByteBuffer blob;
  if (!CPasswordVault::EncryptPassword(Password, blob, error))
  {
    VaultErrorMessage(*this, error);
    return;
  }

  int index = _vault.FindByName(name);
  if (index >= 0)
    _vault.Entries()[(unsigned)index].EncryptedPassword = blob;
  else
  {
    CPasswordVaultEntry entry;
    entry.Name = name;
    entry.EncryptedPassword = blob;
    _vault.Entries().Add(entry);
  }

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

  UString message = L"Delete saved password \"";
  message += entries[index].Name;
  message += L"\"?";
  if (::MessageBoxW(*this, message, L"7-Zip Password Vault", MB_ICONQUESTION | MB_YESNO) != IDYES)
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

  _vault.SetPath(CPasswordVault::GetDefaultPath());
  UString error;
  if (!_vault.Load(error))
    VaultErrorMessage(*this, error);
  FillSavedCombo();

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
  _edit.Attach(GetItem(IDE_PASSWORD_NAME));
  _edit.SetText(Name);
  return CModalDialog::OnInit();
}

void CPasswordNameDialog::OnOK()
{
  _edit.GetText(Name);
  CModalDialog::OnOK();
}

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
  IDT_PASSWORD_VALUE
};
#endif

static UString GetLangText(UInt32 langID, const wchar_t *fallback)
{
  #ifdef Z7_LANG
  const UString s = LangString(langID);
  if (!s.IsEmpty())
    return s;
  #endif
  return UString(fallback);
}

static void VaultErrorMessage(HWND wnd, const UString &message)
{
  // An empty message means the user cancelled a master-password prompt,
  // which is not an error worth reporting.
  if (message.IsEmpty())
    return;
  ::MessageBoxW(wnd, message, PasswordVault_GetCaption(), MB_ICONERROR | MB_OK);
}

UString PasswordVault_MakeDefaultName(const CPasswordVault &vault)
{
  const UString base = GetLangText(IDT_PASSWORD_DEFAULT_NAME, L"未命名");
  for (unsigned n = 1; n < 100000; n++)
  {
    UString s = base;
    s.Add_Space();
    s.Add_UInt32(n);
    if (vault.FindByName(s) < 0)
      return s;
  }
  return base;
}

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
  return CModalDialog::OnInit();
}

void CPasswordEditDialog::OnOK()
{
  _nameEdit.GetText(Name);
  _valueEdit.GetText(Value);
  CModalDialog::OnOK();
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

  _vault.SetPath(CPasswordVault::GetConfiguredPath());
  UString error;
  if (!_vault.Load(*this, error))
    VaultErrorMessage(*this, error);

  CheckButton(IDX_PASSWORD_SHOW, ShowPassword);
  SetTextSpec();
  return CModalDialog::OnInit();
}

bool CPasswordDialog::OnCommand(unsigned code, unsigned itemID, LPARAM lParam)
{
  if (code == EN_CHANGE && itemID == IDE_PASSWORD_PASSWORD)
  {
    OnPasswordTextChanged();
    return true;
  }
  return CDialog::OnCommand(code, itemID, lParam);
}

/* If the user types a name that is stored in the vault, offer to type that
   entry's password. The setting decides between filling it silently and
   asking first. */
void CPasswordDialog::OnPasswordTextChanged()
{
  if (_typingGuard)
    return;

  UString text;
  _passwordEdit.GetText(text);
  if (text.IsEmpty() || text == _lastPromptedName)
    return;

  const int index = _vault.FindByName(text);
  if (index < 0)
    return;

  _lastPromptedName = text;
  const UString &value = _vault.Entries()[(unsigned)index].Password;

  NPasswordVault::CInfo settings;
  settings.Load();

  bool useIt = settings.AutoTypeByName;
  if (!useIt)
  {
    UString message = GetLangText(IDT_PASSWORD_AUTOTYPE_Q, L"");
    message += L"\r\n\r\n";
    message += text;
    useIt = (::MessageBoxW(*this, message, PasswordVault_GetCaption(),
        MB_ICONQUESTION | MB_YESNO) == IDYES);
  }

  if (!useIt)
    return;

  _typingGuard = true;
  Password = value;
  SetTextSpec();
  _typingGuard = false;
}

void CPasswordDialog::ShowSavedPasswords()
{
  CPasswordListDialog dialog(&_vault, _passwordEdit);
  dialog.Create(*this);

  /* The list window writes a picked password straight into the edit box,
     so re-read it. */
  _typingGuard = true;
  _passwordEdit.GetText(Password);
  _typingGuard = false;
  _lastPromptedName.Empty();
}

void CPasswordDialog::CreateNewPassword()
{
  UString current;
  _passwordEdit.GetText(current);

  CPasswordEditDialog dialog(true);
  dialog.Value = current;
  if (dialog.Create(*this) != IDOK)
    return;

  UString name = dialog.Name;
  name.Trim();
  if (name.IsEmpty())
    name = PasswordVault_MakeDefaultName(_vault);

  const int index = _vault.FindByName(name);
  if (index >= 0)
    _vault.Entries()[(unsigned)index].Password = dialog.Value;
  else
  {
    CPasswordVaultEntry entry;
    entry.Name = name;
    entry.Password = dialog.Value;
    _vault.Entries().Add(entry);
  }

  UString error;
  if (!_vault.Save(error))
  {
    VaultErrorMessage(*this, error);
    return;
  }

  _typingGuard = true;
  Password = dialog.Value;
  SetTextSpec();
  _typingGuard = false;
  _lastPromptedName.Empty();
}

/* Called from OnOK: if the password is not in the vault yet, offer to store it. */
void CPasswordDialog::MaybeOfferToSave()
{
  if (Password.IsEmpty())
    return;

  NPasswordVault::CInfo settings;
  settings.Load();
  if (!settings.PromptToSaveNew)
    return;

  {
    const CObjectVector<CPasswordVaultEntry> &entries = _vault.Entries();
    FOR_VECTOR(i, entries)
      if (entries[i].Password == Password)
        return; /* already stored */
  }

  if (::MessageBoxW(*this, GetLangText(IDT_PASSWORD_SAVE_NEW_Q, L""),
      PasswordVault_GetCaption(), MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  CPasswordEditDialog dialog(true);
  dialog.Value = Password;
  if (dialog.Create(*this) != IDOK)
    return;

  UString name = dialog.Name;
  name.Trim();
  if (name.IsEmpty())
    name = PasswordVault_MakeDefaultName(_vault);

  const int index = _vault.FindByName(name);
  if (index >= 0)
    _vault.Entries()[(unsigned)index].Password = dialog.Value;
  else
  {
    CPasswordVaultEntry entry;
    entry.Name = name;
    entry.Password = dialog.Value;
    _vault.Entries().Add(entry);
  }

  UString error;
  if (!_vault.Save(error))
    VaultErrorMessage(*this, error);
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
      ShowSavedPasswords();
      return true;
    case IDB_PASSWORD_NEW:
      CreateNewPassword();
      return true;
  }
  return CDialog::OnButtonClicked(buttonID, buttonHWND);
}

void CPasswordDialog::OnOK()
{
  ReadControls();
  MaybeOfferToSave();
  CModalDialog::OnOK();
}

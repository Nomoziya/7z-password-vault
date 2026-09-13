// PasswordVaultUi.cpp

#include "StdAfx.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "../Common/ZipRegistry.h"

#include "PasswordDialog.h"      // CPasswordEditDialog
#include "PasswordListDialog.h"  // CPasswordListDialog
#include "PasswordVaultUi.h"

using namespace NWindows;
using namespace NControl;

UString PasswordVault_GetText(UInt32 langID, const wchar_t *fallback)
{
  #ifdef Z7_LANG
  {
    const UString s = LangString(langID);
    if (!s.IsEmpty())
      return s;
  }
  #endif
  return UString(fallback);
}

static void VaultErrorMessage(HWND wnd, const UString &message)
{
  if (message.IsEmpty())
    return;
  ::MessageBoxW(wnd, message, PasswordVault_GetCaption(), MB_ICONERROR | MB_OK);
}

CPasswordVaultUi::CPasswordVaultUi():
    _loaded(false),
    _closeAfterFill(true),
    _autoTypeByName(true),
    _promptToSaveNew(true),
    _syncEdit(NULL),
    _selfChange(false)
{
}

CPasswordVaultUi::~CPasswordVaultUi()
{
}

void CPasswordVaultUi::ReadSettings()
{
  NPasswordVault::CInfo settings;
  settings.Load();
  _closeAfterFill = settings.CloseAfterFill;
  _autoTypeByName = settings.AutoTypeByName;
  _promptToSaveNew = settings.PromptToSaveNew;
}

void CPasswordVaultUi::Load(HWND parent)
{
  ReadSettings();
  _vault.SetPath(CPasswordVault::GetConfiguredPath());
  UString error;
  _loaded = _vault.Load(parent, error);
  if (!_loaded)
    VaultErrorMessage(parent, error);
}

void CPasswordVaultUi::SetEditPassword(CEdit &edit, const UString &password)
{
  /* The code is writing, not the user: the resulting EN_CHANGE must not be
     mistaken for typing. */
  _selfChange = true;
  edit.SetText(password);
  if (_syncEdit)
    _syncEdit->SetText(password);
  _selfChange = false;
}

void CPasswordVaultUi::ScheduleAutoType(HWND parent, CEdit &edit)
{
  if (_selfChange)
    return;

  UString text;
  edit.GetText(text);
  _pendingText = text;

  /* Every change restarts the wait. A saved name is therefore only filled in
     after the user stops typing, which is what makes a password that starts
     with a saved name ("cs" saved, "cspass" typed) safe. */
  ::SetTimer(parent, kPasswordVaultAutoTypeTimer, kPasswordVaultAutoTypeDelayMs, NULL);
}


bool CPasswordVaultUi::OnTimer(HWND parent, WPARAM timerID, CEdit &edit)
{
  if (timerID != kPasswordVaultAutoTypeTimer)
    return false;

  ::KillTimer(parent, kPasswordVaultAutoTypeTimer);

  UString text;
  edit.GetText(text);
  if (text.IsEmpty() || text != _pendingText || text == _lastFilledName)
    return true;

  const int index = _vault.FindByName(text);
  if (index < 0)
    return true;

  const CPasswordVaultEntry &entry = _vault.Entries()[(unsigned)index];

  bool useIt = _autoTypeByName;
  if (!useIt)
  {
    UString message = PasswordVault_GetText(IDT_PASSWORD_AUTOTYPE_Q, L"");
    message += L"\r\n\r\n";
    message += text;
    useIt = (::MessageBoxW(parent, message, PasswordVault_GetCaption(),
        MB_ICONQUESTION | MB_YESNO) == IDYES);
  }

  if (!useIt)
    return true;

  _lastFilledName = text;
  SetEditPassword(edit, entry.Password);
  return true;
}

bool CPasswordVaultUi::ShowList(HWND parent, CEdit &edit)
{
  UString before;
  edit.GetText(before);

  CPasswordListDialog dialog(&_vault, (HWND)edit);
  dialog.Create(parent);

  UString after;
  edit.GetText(after);
  if (after == before)
    return false;

  if (_syncEdit)
    _syncEdit->SetText(after);

  /* The list wrote into the edit directly, which raised EN_CHANGE and started
     the auto-type timer. Without this the timer would compare the password that
     was just filled in against the saved names, and a password that happens to
     equal another entry's name would be replaced by that entry's password. */
  _lastFilledName = after;
  return true;
}

bool CPasswordVaultUi::AddOrUpdate(HWND parent, const UString &name, const UString &password)
{
  /* An empty name never identifies an entry: two unnamed entries have to stay
     two entries instead of overwriting each other. */
  const int index = name.IsEmpty() ? -1 : _vault.FindByName(name);

  if (index >= 0)
    _vault.Entries()[(unsigned)index].Password = password;
  else
  {
    CPasswordVaultEntry entry;
    entry.Name = name;
    entry.Password = password;
    _vault.Entries().Add(entry);
  }

  UString error;
  if (!_vault.Save(error, parent))
  {
    VaultErrorMessage(parent, error);
    return false;
  }
  return true;
}

void CPasswordVaultUi::CreateNew(HWND parent, CEdit *edit)
{
  UString current;
  if (edit)
    edit->GetText(current);

  CPasswordEditDialog dialog(true);
  dialog.Value = current;
  if (dialog.Create(parent) != IDOK)
    return;

  UString name = dialog.Name;
  name.Trim();
  if (!AddOrUpdate(parent, name, dialog.Value))
    return;

  if (edit)
    SetEditPassword(*edit, dialog.Value);
}

void CPasswordVaultUi::OfferToSave(HWND parent, const UString &password)
{
  if (password.IsEmpty() || !_promptToSaveNew)
    return;

  {
    const CObjectVector<CPasswordVaultEntry> &entries = _vault.Entries();
    FOR_VECTOR(i, entries)
      if (entries[i].Password == password)
        return; /* already stored */
  }

  if (::MessageBoxW(parent, PasswordVault_GetText(IDT_PASSWORD_SAVE_NEW_Q, L""),
      PasswordVault_GetCaption(), MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  CPasswordEditDialog dialog(true);
  dialog.Value = password;
  if (dialog.Create(parent) != IDOK)
    return;

  UString name = dialog.Name;
  name.Trim();
  AddOrUpdate(parent, name, dialog.Value);
}

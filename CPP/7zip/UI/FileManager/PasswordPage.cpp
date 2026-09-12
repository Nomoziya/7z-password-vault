// PasswordPage.cpp

#include "StdAfx.h"

#include "../Common/ZipRegistry.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "BrowseDialog.h"
#include "PasswordPage.h"
#include "PasswordPageRes.h"
#include "PasswordVault.h"

using namespace NWindows;

#ifdef Z7_LANG
static const UInt32 kLangIDs[] =
{
  IDT_PASSWORD_VAULT_PATH,
  IDX_PASSWORD_USE_MASTER,
  IDX_PASSWORD_REMEMBER,
  IDX_PASSWORD_AUTOFILL,
  IDX_PASSWORD_SHOW_DEFAULT,
  IDB_PASSWORD_SET_MASTER,
  IDB_PASSWORD_VAULT_BROWSE
};
#endif

void CPasswordPage::ModifiedEvent()
{
  if (_initMode)
    return;
  _needSave = true;
  Changed();
}

bool CPasswordPage::OnInit()
{
  _initMode = true;
  _needSave = false;

  #ifdef Z7_LANG
  LangSetDlgItems(*this, kLangIDs, Z7_ARRAY_SIZE(kLangIDs));
  #endif

  _vaultPathEdit.Attach(GetItem(IDE_PASSWORD_VAULT_PATH));

  NPasswordVault::CInfo settings;
  settings.Load();

  _oldVaultPath = settings.VaultPath;
  _oldUseMaster = settings.UseMasterPassword;

  _vaultPathEdit.SetText(settings.VaultPath);
  CheckButton(IDX_PASSWORD_USE_MASTER, settings.UseMasterPassword);
  CheckButton(IDX_PASSWORD_REMEMBER, settings.RememberMasterPassword);
  CheckButton(IDX_PASSWORD_AUTOFILL, settings.AutoFill);
  CheckButton(IDX_PASSWORD_SHOW_DEFAULT, NExtract::Read_ShowPassword());

  _initMode = false;
  return CPropertyPage::OnInit();
}

void CPasswordPage::OnBrowse()
{
  UString currentPath;
  _vaultPathEdit.GetText(currentPath);
  UString resultPath;
  if (MyBrowseForFolder(*this, L"选择密码库文件夹", currentPath, resultPath))
    _vaultPathEdit.SetText(resultPath);
}

void CPasswordPage::OnSetMasterPassword()
{
  UString error;

  UString pathU;
  _vaultPathEdit.GetText(pathU);
  pathU.Trim();
  const UString vaultPath = pathU.IsEmpty() ? CPasswordVault::GetDefaultPath() : pathU;

  /* Load the existing vault FIRST. If it is already encrypted with a master
     password, this asks for the OLD password (or uses the cached one).
     Doing this before replacing the cached password is essential: otherwise
     the NEW password would be used to decrypt the OLD file and fail. */
  CPasswordVault vault;
  vault.SetPath(vaultPath);
  if (!vault.Load(*this, error))
  {
    if (!error.IsEmpty())
      ::MessageBoxW(*this, error, L"7-Zip 密码管家", MB_ICONERROR | MB_OK);
    return;
  }
  UString pw1, pw2;
  if (!CPasswordVault::PromptForMasterPassword(*this, pw1, error))
    return;
  if (!CPasswordVault::PromptForMasterPassword(*this, pw2, error))
    return;

  if (pw1.IsEmpty())
  {
    ::MessageBoxW(*this, L"主密码不能为空。", L"7-Zip 密码管家", MB_ICONWARNING | MB_OK);
    return;
  }
  if (pw1 != pw2)
  {
    ::MessageBoxW(*this, L"两次输入的密码不一致。", L"7-Zip 密码管家", MB_ICONWARNING | MB_OK);
    return;
  }

  // Switch to master-password mode, then re-encrypt the vault with the new password.
  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.UseMasterPassword = true;
    settings.VaultPath = us2fs(vaultPath);
    settings.Save();
  }

  CPasswordVault::SetCachedMasterPassword(pw1);

  if (!vault.Save(error))
  {
    ::MessageBoxW(*this, error, L"7-Zip 密码管家", MB_ICONERROR | MB_OK);
    return;
  }

  CheckButton(IDX_PASSWORD_USE_MASTER, true);
  _oldUseMaster = true;
  _oldVaultPath = us2fs(vaultPath);
  _needSave = true;
  Changed();
}

bool CPasswordPage::OnButtonClicked(unsigned buttonID, HWND buttonHWND)
{
  switch (buttonID)
  {
    case IDB_PASSWORD_VAULT_BROWSE:
      OnBrowse();
      return true;
    case IDB_PASSWORD_SET_MASTER:
      OnSetMasterPassword();
      return true;
    case IDX_PASSWORD_USE_MASTER:
    case IDX_PASSWORD_REMEMBER:
    case IDX_PASSWORD_AUTOFILL:
    case IDX_PASSWORD_SHOW_DEFAULT:
      ModifiedEvent();
      return true;
  }
  return CPropertyPage::OnButtonClicked(buttonID, buttonHWND);
}

bool CPasswordPage::OnCommand(unsigned code, unsigned itemID, LPARAM param)
{
  if (code == EN_CHANGE && itemID == IDE_PASSWORD_VAULT_PATH)
  {
    ModifiedEvent();
    return true;
  }
  return CPropertyPage::OnCommand(code, itemID, param);
}

LONG CPasswordPage::OnApply()
{
  if (!_needSave)
    return PSNRET_NOERROR;

  UString pathU;
  _vaultPathEdit.GetText(pathU);
  pathU.Trim();
  const FString newVaultPath = us2fs(pathU);
  const bool newUseMaster = IsButtonCheckedBool(IDX_PASSWORD_USE_MASTER);

  NPasswordVault::CInfo settings;
  settings.Load();
  settings.VaultPath = newVaultPath;
  settings.UseMasterPassword = newUseMaster;
  settings.RememberMasterPassword = IsButtonCheckedBool(IDX_PASSWORD_REMEMBER);
  settings.AutoFill = IsButtonCheckedBool(IDX_PASSWORD_AUTOFILL);
  settings.Save();

  NExtract::Save_ShowPassword(IsButtonCheckedBool(IDX_PASSWORD_SHOW_DEFAULT));

  // Re-encrypt the vault when the encryption mode or the path changed.
  const bool pathChanged = (newVaultPath != _oldVaultPath);
  const bool modeChanged = (newUseMaster != _oldUseMaster);
  if (modeChanged || pathChanged)
  {
    UString error;
    CPasswordVault vault;
    vault.SetPath(_oldVaultPath.IsEmpty() ? CPasswordVault::GetDefaultPath() : _oldVaultPath);
    if (vault.Load(*this, error))
    {
      vault.SetPath(newVaultPath.IsEmpty() ? CPasswordVault::GetDefaultPath() : newVaultPath);
      if (!vault.Save(error))
        ::MessageBoxW(*this, error, L"7-Zip 密码管家", MB_ICONERROR | MB_OK);
    }
    else if (!error.IsEmpty())
    {
      ::MessageBoxW(*this, error, L"7-Zip 密码管家", MB_ICONERROR | MB_OK);
    }
  }

  _oldVaultPath = newVaultPath;
  _oldUseMaster = newUseMaster;
  _needSave = false;
  return PSNRET_NOERROR;
}

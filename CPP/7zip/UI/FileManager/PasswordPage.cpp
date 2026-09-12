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
  IDX_PASSWORD_AUTOLOCK,
  IDB_PASSWORD_SET_MASTER,
  IDB_PASSWORD_CLEAR_MASTER,
  IDX_PASSWORD_SHOW_DEFAULT,
  IDX_PASSWORD_EDIT_RIGHT,
  IDX_PASSWORD_AUTOTYPE,
  IDX_PASSWORD_PROMPT_SAVE,
  IDB_PASSWORD_VAULT_BROWSE,
  IDB_PASSWORD_EXPORT,
  IDB_PASSWORD_IMPORT
};
#endif

static void ErrorBox(HWND wnd, const UString &message)
{
  if (message.IsEmpty())
    return;
  ::MessageBoxW(wnd, message, PasswordVault_GetCaption(), MB_ICONERROR | MB_OK);
}

static void InfoBox(HWND wnd, const UString &message)
{
  ::MessageBoxW(wnd, message, PasswordVault_GetCaption(), MB_ICONINFORMATION | MB_OK);
}

static bool FileExists(const UString &path)
{
  return ::GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

void CPasswordPage::ModifiedEvent()
{
  if (_initMode)
    return;
  _needSave = true;
  Changed();
}

UString CPasswordPage::GetVaultPathFromUi()
{
  UString pathU;
  _vaultPathEdit.GetText(pathU);
  pathU.Trim();
  if (pathU.IsEmpty())
    return CPasswordVault::GetDefaultPath();
  return pathU;
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
  CheckButton(IDX_PASSWORD_AUTOLOCK, settings.AutoLockMaster);
  CheckButton(IDX_PASSWORD_EDIT_RIGHT, settings.EditByRightClick);
  CheckButton(IDX_PASSWORD_AUTOTYPE, settings.AutoTypeByName);
  CheckButton(IDX_PASSWORD_PROMPT_SAVE, settings.PromptToSaveNew);
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
  const UString vaultPath = GetVaultPathFromUi();

  /* Load the existing vault FIRST. If it is already encrypted with a master
     password, this asks for the OLD password (or uses the cached one).
     Doing this before replacing the cached password is essential: otherwise
     the NEW password would be used to decrypt the OLD file and fail. */
  CPasswordVault vault;
  vault.SetPath(vaultPath);
  if (!vault.Load(*this, error))
  {
    ErrorBox(*this, error);
    return;
  }

  UString pw1, pw2;
  if (!CPasswordVault::PromptForMasterPassword(*this, pw1, error))
    return;
  if (!CPasswordVault::PromptForMasterPassword(*this, pw2, error))
    return;

  if (pw1.IsEmpty())
  {
    ::MessageBoxW(*this, L"主密码不能为空。", PasswordVault_GetCaption(), MB_ICONWARNING | MB_OK);
    return;
  }
  if (pw1 != pw2)
  {
    ::MessageBoxW(*this, L"两次输入的密码不一致。", PasswordVault_GetCaption(), MB_ICONWARNING | MB_OK);
    return;
  }

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
    ErrorBox(*this, error);
    return;
  }

  CheckButton(IDX_PASSWORD_USE_MASTER, true);
  _oldUseMaster = true;
  _oldVaultPath = us2fs(vaultPath);
  _needSave = true;
  Changed();
}

void CPasswordPage::OnClearMasterPassword()
{
  UString error;
  const UString vaultPath = GetVaultPathFromUi();

  CPasswordVault vault;
  vault.SetPath(vaultPath);
  if (!vault.Load(*this, error))
  {
    ErrorBox(*this, error);
    return;
  }

  if (::MessageBoxW(*this,
      L"确定要清除主密码吗？\n\n清除后将改用 Windows 凭据（DPAPI）加密，"
      L"密码库只能在本机本账户下解密。",
      PasswordVault_GetCaption(), MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.UseMasterPassword = false;
    settings.VaultPath = us2fs(vaultPath);
    settings.Save();
  }
  CPasswordVault::ClearCachedMasterPassword();

  if (!vault.Save(error))
  {
    ErrorBox(*this, error);
    return;
  }

  CheckButton(IDX_PASSWORD_USE_MASTER, false);
  _oldUseMaster = false;
  _oldVaultPath = us2fs(vaultPath);
  _needSave = true;
  Changed();
  InfoBox(*this, L"主密码已清除，密码库已改用 DPAPI 加密。");
}

void CPasswordPage::OnExport()
{
  const UString vaultPath = GetVaultPathFromUi();
  if (!FileExists(vaultPath))
  {
    InfoBox(*this, L"密码库文件还不存在，请先保存至少一条密码。");
    return;
  }

  CBrowseInfo bi;
  bi.hwndOwner = *this;
  bi.SaveMode = true;
  bi.lpstrTitle = L"导出密码库";
  bi.FilePath = vaultPath;

  CObjectVector<CBrowseFilterInfo> filters;
  {
    CBrowseFilterInfo f;
    f.Description = L"密码库文件";
    f.Masks.Add(L"*.dat");
    filters.Add(f);
  }
  if (!bi.BrowseForFile(filters))
    return;

  if (!::CopyFileW(vaultPath, bi.FilePath, TRUE))
  {
    ErrorBox(*this, L"导出失败，无法写入目标文件。");
    return;
  }

  InfoBox(*this,
      L"密码库已导出。\n\n注意：DPAPI 模式下导出的文件只能在同一台电脑的同一 "
      L"Windows 账户下解密；主密码模式下可在其它电脑用主密码解密。");
}

void CPasswordPage::OnImport()
{
  CBrowseInfo bi;
  bi.hwndOwner = *this;
  bi.SaveMode = false;
  bi.lpstrTitle = L"导入密码库";

  CObjectVector<CBrowseFilterInfo> filters;
  {
    CBrowseFilterInfo f;
    f.Description = L"密码库文件";
    f.Masks.Add(L"*.dat");
    filters.Add(f);
  }
  if (!bi.BrowseForFile(filters))
    return;

  UString error;
  CPasswordVault src;
  src.SetPath(bi.FilePath);
  if (!src.Load(*this, error))
  {
    ErrorBox(*this, error);
    return;
  }

  const UString vaultPath = GetVaultPathFromUi();
  CPasswordVault dst;
  dst.SetPath(vaultPath);
  if (!dst.Load(*this, error))
  {
    ErrorBox(*this, error);
    return;
  }

  unsigned added = 0;
  unsigned updated = 0;
  const CObjectVector<CPasswordVaultEntry> &srcEntries = src.Entries();
  FOR_VECTOR(i, srcEntries)
  {
    const CPasswordVaultEntry &entry = srcEntries[i];
    const int index = dst.FindByName(entry.Name);
    if (index >= 0)
    {
      dst.Entries()[(unsigned)index].Password = entry.Password;
      updated++;
    }
    else
    {
      dst.Entries().Add(entry);
      added++;
    }
  }

  if (!dst.Save(error))
  {
    ErrorBox(*this, error);
    return;
  }

  UString msg = L"导入完成：新增 ";
  msg.Add_UInt32(added);
  msg += L" 条，更新 ";
  msg.Add_UInt32(updated);
  msg += L" 条。";
  InfoBox(*this, msg);
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
    case IDB_PASSWORD_CLEAR_MASTER:
      OnClearMasterPassword();
      return true;
    case IDB_PASSWORD_EXPORT:
      OnExport();
      return true;
    case IDB_PASSWORD_IMPORT:
      OnImport();
      return true;
    case IDX_PASSWORD_USE_MASTER:
    case IDX_PASSWORD_REMEMBER:
    case IDX_PASSWORD_AUTOLOCK:
    case IDX_PASSWORD_EDIT_RIGHT:
    case IDX_PASSWORD_AUTOTYPE:
    case IDX_PASSWORD_PROMPT_SAVE:
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

  const bool newUseMaster = IsButtonCheckedBool(IDX_PASSWORD_USE_MASTER);
  const bool remember = IsButtonCheckedBool(IDX_PASSWORD_REMEMBER);

  NPasswordVault::CInfo settings;
  settings.Load();
  settings.VaultPath = us2fs(pathU);
  settings.UseMasterPassword = newUseMaster;
  settings.RememberMasterPassword = remember;
  settings.AutoLockMaster = IsButtonCheckedBool(IDX_PASSWORD_AUTOLOCK);
  settings.EditByRightClick = IsButtonCheckedBool(IDX_PASSWORD_EDIT_RIGHT);
  settings.AutoTypeByName = IsButtonCheckedBool(IDX_PASSWORD_AUTOTYPE);
  settings.PromptToSaveNew = IsButtonCheckedBool(IDX_PASSWORD_PROMPT_SAVE);
  settings.Save();

  NExtract::Save_ShowPassword(IsButtonCheckedBool(IDX_PASSWORD_SHOW_DEFAULT));

  if (!remember)
    CPasswordVault::ClearCachedMasterPassword();

  // Re-encrypt the vault when the encryption mode or the location changed.
  const UString oldPath = _oldVaultPath.IsEmpty() ? CPasswordVault::GetDefaultPath() : fs2us(_oldVaultPath);
  const UString newPath = pathU.IsEmpty() ? CPasswordVault::GetDefaultPath() : pathU;
  const bool pathChanged = (newPath != oldPath);
  const bool modeChanged = (newUseMaster != _oldUseMaster);

  if (modeChanged || pathChanged)
  {
    UString error;
    CPasswordVault vault;
    vault.SetPath(oldPath);
    if (!vault.Load(*this, error))
    {
      ErrorBox(*this, error);
    }
    else
    {
      vault.SetPath(newPath);
      if (!vault.Save(error))
      {
        ErrorBox(*this, error);
      }
      else if (pathChanged && FileExists(oldPath))
      {
        UString msg = L"密码库已写入新位置：\r\n";
        msg += newPath;
        msg += L"\r\n\r\n是否删除旧位置的密码库文件？\r\n";
        msg += oldPath;
        if (::MessageBoxW(*this, msg, PasswordVault_GetCaption(), MB_ICONQUESTION | MB_YESNO) == IDYES)
          ::DeleteFileW(oldPath);
      }
    }
  }

  _oldVaultPath = us2fs(pathU);
  _oldUseMaster = newUseMaster;
  _needSave = false;
  return PSNRET_NOERROR;
}

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

// An unsuccessful settings operation must never retain a password acquired
// during its load/prompt/save sequence, including cancellations and exceptions.
class CPageMasterCacheGuard
{
  bool _success;
public:
  CPageMasterCacheGuard(): _success(false) {}
  void Commit() { _success = true; }
  ~CPageMasterCacheGuard()
  {
    if (!_success) CPasswordVault::ClearCachedMasterPassword();
  }
};

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
  IDX_PASSWORD_CLOSE_FILL,
  IDX_PASSWORD_AUTOTYPE,
  IDX_PASSWORD_PROMPT_SAVE,
  IDB_PASSWORD_VAULT_BROWSE,
  IDB_PASSWORD_EXPORT,
  IDB_PASSWORD_IMPORT,
  IDX_PASSWORD_HIDE_LIST,
  IDX_PASSWORD_UNNAMED_PW
};
#endif

static void ErrorBox(HWND wnd, const UString &message)
{
  CPasswordVault::ClearCachedMasterPassword();
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
  pathU = PasswordVault_NormalizePath(pathU);
  if (pathU.IsEmpty())
    return CPasswordVault::GetDefaultPath();
  return pathU;
}

bool CPasswordPage::OnInit()
{
  _initMode = true;
  _needSave = false;
  _suppressChange = false;

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
  CheckButton(IDX_PASSWORD_CLOSE_FILL, settings.CloseAfterFill);
  CheckButton(IDX_PASSWORD_AUTOTYPE, settings.AutoTypeByName);
  CheckButton(IDX_PASSWORD_PROMPT_SAVE, settings.PromptToSaveNew);
  CheckButton(IDX_PASSWORD_HIDE_LIST, settings.ShowPasswordInList);
  CheckButton(IDX_PASSWORD_UNNAMED_PW, settings.ShowPasswordForUnnamed);
  CheckButton(IDX_PASSWORD_SHOW_DEFAULT, NExtract::Read_ShowPassword());

  _initMode = false;
  return CPropertyPage::OnInit();
}

void CPasswordPage::OnBrowse()
{
  UString currentPath;
  _vaultPathEdit.GetText(currentPath);
  UString resultPath;
  const UString title = PasswordVault_GetText(IDT_PASSWORD_PICK_FOLDER, L"选择密码库文件夹");
  if (MyBrowseForFolder(*this, title, currentPath, resultPath))
  {
    _vaultPathEdit.SetText(resultPath);
    /* SetText does not raise EN_CHANGE, and that notification is what enables Apply:
       without it, choosing a folder and pressing OK applied nothing. */
    ModifiedEvent();
  }
}

void CPasswordPage::OnSetMasterPassword()
{
  CPageMasterCacheGuard cacheGuard;
  UString error;
  const UString vaultPath = GetVaultPathFromUi();

  bool oldUseMaster = false;
  {
    NPasswordVault::CInfo before;
    before.Load();
    oldUseMaster = before.UseMasterPassword;
  }

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

  CVaultString pw1, pw2;
  if (!CPasswordVault::PromptForMasterPassword(*this, pw1, error))
    return;
  if (!CPasswordVault::PromptForMasterPassword(*this, pw2, error))
    return;

  if (pw1.IsEmpty())
  {
    ::MessageBoxW(*this, PasswordVault_GetText(IDT_PASSWORD_MASTER_EMPTY, L"主密码不能为空。"),
        PasswordVault_GetCaption(), MB_ICONWARNING | MB_OK);
    return;
  }
  if (pw1 != pw2)
  {
    ::MessageBoxW(*this, PasswordVault_GetText(IDT_PASSWORD_MASTER_MISMATCH, L"两次输入的密码不一致。"),
        PasswordVault_GetCaption(), MB_ICONWARNING | MB_OK);
    return;
  }

  /* The mode has to be stored BEFORE the file is written, because Save() takes it
     from the settings - but only now that both prompts were answered and the passwords
     were checked: storing it earlier meant that cancelling the prompt left the registry
     saying "master password mode" while the file was still DPAPI, and every later start
     could not read it. */
  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.UseMasterPassword = true;
    settings.VaultPath = us2fs(vaultPath);
    settings.Save();
  }

  CPasswordVault::SetCachedMasterPassword(pw1);

  /* The user asked for master password mode: the mode is a decision, not something to
     derive from the file that is being replaced. */
  if (!vault.Save(error, *this, 1))
  {
    NPasswordVault::CInfo back;
    back.Load();
    back.UseMasterPassword = oldUseMaster;
    back.Save();
    CPasswordVault::ClearCachedMasterPassword();
    ErrorBox(*this, error);
    return;
  }

  CheckButton(IDX_PASSWORD_USE_MASTER, true);
  cacheGuard.Commit();
  _oldUseMaster = true;
  _oldVaultPath = us2fs(vaultPath);
  _needSave = true;
  Changed();
}

void CPasswordPage::OnClearMasterPassword()
{
  CPageMasterCacheGuard cacheGuard;
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
      PasswordVault_GetText(IDT_PASSWORD_CLEAR_MASTER_Q,
        L"确定要清除主密码吗？\n\n清除后将改用 Windows 凭据（DPAPI）加密，"
        L"密码库只能在本机本账户下解密。"),
      PasswordVault_GetCaption(), MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  /* Same as when setting it: store the mode, and put the previous one back if the
     file cannot be written. */
  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.UseMasterPassword = false;
    settings.VaultPath = us2fs(vaultPath);
    settings.Save();
  }
  CPasswordVault::ClearCachedMasterPassword();

  if (!vault.Save(error, *this, 0))
  {
    NPasswordVault::CInfo back;
    back.Load();
    back.UseMasterPassword = true;
    back.Save();
    ErrorBox(*this, error);
    return;
  }

  CheckButton(IDX_PASSWORD_USE_MASTER, false);
  cacheGuard.Commit();
  _oldUseMaster = false;
  _oldVaultPath = us2fs(vaultPath);
  _needSave = true;
  Changed();
  InfoBox(*this, PasswordVault_GetText(IDT_PASSWORD_CLEAR_MASTER_DONE,
      L"主密码已清除，密码库已改用 DPAPI 加密。"));
}

void CPasswordPage::OnExport()
{
  const UString vaultPath = GetVaultPathFromUi();
  if (!FileExists(vaultPath))
  {
    InfoBox(*this, PasswordVault_GetText(IDT_PASSWORD_NO_VAULT_FILE,
        L"密码库文件还不存在，请先保存至少一条密码。"));
    return;
  }

  CBrowseInfo bi;
  bi.hwndOwner = *this;
  bi.SaveMode = true;
  const UString exportTitle = PasswordVault_GetText(IDT_PASSWORD_EXPORT_TITLE, L"导出密码库");
  bi.lpstrTitle = exportTitle;
  bi.FilePath = vaultPath;

  CObjectVector<CBrowseFilterInfo> filters;
  {
    CBrowseFilterInfo f;
    f.Description = PasswordVault_GetText(IDT_PASSWORD_FILE_FILTER, L"密码库文件");
    f.Masks.Add(L"*.dat");
    filters.Add(f);
  }
  if (!bi.BrowseForFile(filters))
    return;

  if (!::CopyFileW(vaultPath, bi.FilePath, TRUE))
  {
    ErrorBox(*this, PasswordVault_GetText(IDT_PASSWORD_EXPORT_FAILED,
        L"导出失败，无法写入目标文件。"));
    return;
  }

  InfoBox(*this, PasswordVault_GetText(IDT_PASSWORD_EXPORT_DONE,
      L"密码库已导出。\n\n注意：DPAPI 模式下导出的文件只能在同一台电脑的同一 "
      L"Windows 账户下解密；主密码模式下可在其它电脑用主密码解密。"));
}

void CPasswordPage::OnImport()
{
  CPageMasterCacheGuard cacheGuard;
  CBrowseInfo bi;
  bi.hwndOwner = *this;
  bi.SaveMode = false;
  const UString importTitle = PasswordVault_GetText(IDT_PASSWORD_IMPORT_TITLE, L"导入密码库");
  bi.lpstrTitle = importTitle;

  CObjectVector<CBrowseFilterInfo> filters;
  {
    CBrowseFilterInfo f;
    f.Description = PasswordVault_GetText(IDT_PASSWORD_FILE_FILTER, L"密码库文件");
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

  CObjectVector<CPasswordVaultEntry> before(dst.Entries());
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

  if (!dst.Save(error, *this))
  {
    dst.ClearEntries();
    dst.Entries() = before;
    ErrorBox(*this, error);
    return;
  }

  /* The two counts are substituted into a localized string: the word order
     differs between languages, so the markers cannot be split apart in code. */
  UString msg = PasswordVault_GetText(IDT_PASSWORD_IMPORT_DONE,
      L"导入完成：新增 {0} 条，更新 {1} 条。");
  {
    UString n;
    n.Add_UInt32(added);
    msg.Replace(UString(L"{0}"), n);
    n.Empty();
    n.Add_UInt32(updated);
    msg.Replace(UString(L"{1}"), n);
  }
  InfoBox(*this, msg);
  cacheGuard.Commit();
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
    case IDX_PASSWORD_CLOSE_FILL:
    case IDX_PASSWORD_AUTOTYPE:
    case IDX_PASSWORD_HIDE_LIST:
    case IDX_PASSWORD_UNNAMED_PW:
    case IDX_PASSWORD_PROMPT_SAVE:
    case IDX_PASSWORD_SHOW_DEFAULT:
      ModifiedEvent();
      return true;
  }
  return CPropertyPage::OnButtonClicked(buttonID, buttonHWND);
}

bool CPasswordPage::OnCommand(unsigned code, unsigned itemID, LPARAM param)
{
  if (_suppressChange)
    return CDialog::OnCommand(code, itemID, param);

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
  CPageMasterCacheGuard cacheGuard;

  UString pathU;
  _vaultPathEdit.GetText(pathU);
  /* A folder is accepted and means "the vault file lives in this folder". */
  pathU = PasswordVault_NormalizePath(pathU);

  const bool newUseMaster = IsButtonCheckedBool(IDX_PASSWORD_USE_MASTER);
  const bool remember = IsButtonCheckedBool(IDX_PASSWORD_REMEMBER);

  const UString oldPath = _oldVaultPath.IsEmpty() ? CPasswordVault::GetDefaultPath() : fs2us(_oldVaultPath);
  const UString newPath = pathU.IsEmpty() ? CPasswordVault::GetDefaultPath() : pathU;
  const bool pathChanged = (newPath != oldPath);
  const bool modeChanged = (newUseMaster != _oldUseMaster);
  const bool reEncrypt = (modeChanged || pathChanged);

  /* The vault must be READ before the new mode is written: Load() takes the mode
     from the settings, so reading an old-format file with the new mode already
     stored would fail. It is rewritten below, and only a successful rewrite
     leaves the new mode stored. */
  CPasswordVault vault;
  bool oldVaultReadable = true;
  if (reEncrypt)
  {
    UString error;
    vault.SetPath(oldPath);
    if (!vault.Load(*this, error))
    {
      /* An unreadable source aborts the transaction without writing preferences. */
      oldVaultReadable = false;
      if (!error.IsEmpty())
        ErrorBox(*this, error);
    }
  }

  if (!oldVaultReadable && reEncrypt)
  {
    CPasswordVault::ClearCachedMasterPassword();
    /* The old vault could not be read and the location changed: storing the new path
       would point the program at a file that has never been written, while the real
       passwords stay behind - and the next save would create an empty vault there.
       Nothing is stored; the user can change the location once the old file is usable. */
    ::MessageBoxW(*this, PasswordVault_GetText(IDT_PASSWORD_PATH_NEEDS_VAULT,
        L"无法读取当前密码库，因此没有更改位置。\n\n请先确认旧文件可以打开（或把它改名后重试），再修改位置。"),
        PasswordVault_GetCaption(), MB_ICONWARNING | MB_OK);
    return PSNRET_INVALID_NOCHANGEPAGE;
  }

  // Enabling master mode through the checkbox also requires confirmation.
  if (modeChanged && newUseMaster)
  {
    UString error;
    CVaultString first, second;
    if (!CPasswordVault::PromptForMasterPassword(*this, first, error) ||
        !CPasswordVault::PromptForMasterPassword(*this, second, error))
      return PSNRET_INVALID_NOCHANGEPAGE;
    if (first.IsEmpty() || first != second)
    {
      ErrorBox(*this, PasswordVault_GetText(IDT_PASSWORD_MASTER_MISMATCH,
          L"两次输入的密码不一致，或密码为空。"));
      return PSNRET_INVALID_NOCHANGEPAGE;
    }
    CPasswordVault::SetCachedMasterPassword(first);
  }
  if (reEncrypt && oldVaultReadable)
  {
    UString error;
    CPasswordVault destination;
    bool saved = false;
    if (pathChanged)
    {
      // Copy to a new location only. Keep the original as a recovery copy;
      // replacing/merging an existing destination requires the Import action.
      destination.SetPath(newPath);
      if (FileExists(newPath))
        error = PasswordVault_GetText(IDT_PASSWORD_ERR_CHANGED,
            L"目标位置已存在密码库，请使用导入功能合并。");
      else if (destination.Load(*this, error))
      {
        destination.Entries() = vault.Entries();
        saved = destination.Save(error, *this, newUseMaster ? 1 : 0);
      }
    }
    else
      saved = vault.Save(error, *this, newUseMaster ? 1 : 0);
    if (!saved)
    {
      ErrorBox(*this, error);
      return PSNRET_INVALID_NOCHANGEPAGE;
    }

  }

  // Commit all preferences only after migration/re-encryption succeeds.
  {
    NPasswordVault::CInfo settings;
    settings.Load();
    settings.VaultPath = us2fs(pathU);
    settings.UseMasterPassword = newUseMaster;
    settings.RememberMasterPassword = remember;
    settings.AutoLockMaster = IsButtonCheckedBool(IDX_PASSWORD_AUTOLOCK);
    settings.CloseAfterFill = IsButtonCheckedBool(IDX_PASSWORD_CLOSE_FILL);
    settings.AutoTypeByName = IsButtonCheckedBool(IDX_PASSWORD_AUTOTYPE);
    settings.PromptToSaveNew = IsButtonCheckedBool(IDX_PASSWORD_PROMPT_SAVE);
    settings.ShowPasswordInList = IsButtonCheckedBool(IDX_PASSWORD_HIDE_LIST);
    settings.ShowPasswordForUnnamed = IsButtonCheckedBool(IDX_PASSWORD_UNNAMED_PW);
    settings.Save();
  }

  NExtract::Save_ShowPassword(IsButtonCheckedBool(IDX_PASSWORD_SHOW_DEFAULT));


  /* Show the path that is really used, so a folder entry is visibly resolved to
     the file inside it. The page must not look modified again afterwards, so the
     resulting EN_CHANGE is suppressed. */
  _suppressChange = true;
  _vaultPathEdit.SetText(newPath);
  _suppressChange = false;

  if (!remember) CPasswordVault::ClearCachedMasterPassword();
  _oldVaultPath = us2fs(pathU);
  _oldUseMaster = newUseMaster;
  _needSave = false;
  cacheGuard.Commit();
  return PSNRET_NOERROR;
}

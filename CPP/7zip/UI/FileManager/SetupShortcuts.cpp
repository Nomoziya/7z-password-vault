// SetupShortcuts.cpp
//
// The convenient part of "installing" without an installer: a Start Menu shortcut, a desktop
// shortcut and an entry in "Apps & features", created by the program itself on its first
// start after asking the user.
//
// Why here and not in the package's install script: the self-extracting stub that ships with
// 7-Zip (7z.sfx) cannot run a program after unpacking - measured, it ignores RunProgram and
// InstallPath - and "unpack an archive, then run a script that writes to the registry" is one
// of the shapes that anti-virus engines score as a dropper. Doing it in the program with
// IShellLink and HKCU writes with no script interpreter involved removes both problems.
//
// Everything is per-user: HKEY_CURRENT_USER only, no administrator rights, nothing that the
// uninstaller has to run with elevation.

#include "StdAfx.h"
#include "SetupShortcuts.h"

#include "PasswordVault.h"
#include "PasswordDialogRes.h"

#include "../../../Windows/Registry.h"
#include "../../../Common/MyCom.h"
#include "../../../../C/7zVersion.h"   // MY_VERSION_NUMBERS: the version shown in the entry

#include <shlobj.h>
#include <shellapi.h>

using namespace NWindows;

static const wchar_t * const kKeyPath = L"Software\\7-Zip\\PasswordVault";
/* Set once the question has been answered - yes or no. Its presence is what makes the
   question appear exactly once, so a "no" is remembered as well. */
static const wchar_t * const kAskedValue = L"SetupAsked";

static const wchar_t * const kUninstallKeyPath =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\7ZipPasswordVault";

static const wchar_t * const kProduct = L"7-Zip Password Vault";
static const wchar_t * const kPublisher = L"Nomoziya";
static const wchar_t * const kFmExe = L"7zFM.exe";
static const wchar_t * const kUninstallCmd = L"uninstall.cmd";

/* The version shown in "Apps & features" is the upstream version, the same string the About
   box shows; the fork's own release number lives in the release notes instead of drifting
   apart from the binary. */
#define kDisplayName  L"7-Zip Password Vault " L"" MY_VERSION_NUMBERS
#define kDisplayVer   L"" MY_VERSION_NUMBERS

static const unsigned kPathBufSize = 1024;

static bool GetOwnFolder(UString &folder)
{
  wchar_t buf[kPathBufSize];
  const DWORD len = ::GetModuleFileNameW(NULL, buf, kPathBufSize);
  if (len == 0 || len >= kPathBufSize)
    return false;
  unsigned i = (unsigned)len;
  while (i > 0 && buf[i - 1] != L'\\' && buf[i - 1] != L'/')
    i--;
  if (i == 0)
    return false;
  /* without the separator: the callers add it where they need it */
  folder.SetFrom(buf, i - 1);
  return true;
}

static bool AlreadyAsked()
{
  NRegistry::CKey key;
  if (key.Open(HKEY_CURRENT_USER, kKeyPath) != ERROR_SUCCESS)
    return false;
  UInt32 value = 0;
  if (key.GetValue_UInt32_IfOk(kAskedValue, value) != ERROR_SUCCESS)
    return false;
  return value != 0;
}

static void MarkAsked()
{
  NRegistry::CKey key;
  if (key.Create(HKEY_CURRENT_USER, kKeyPath) == ERROR_SUCCESS)
    key.SetValue(kAskedValue, (UInt32)1);
}

static bool SetStringValue(const wchar_t *keyPath, const wchar_t *name, const UString &value)
{
  NRegistry::CKey key;
  if (key.Create(HKEY_CURRENT_USER, keyPath) != ERROR_SUCCESS)
    return false;
  return key.SetValue(name, (LPCWSTR)value) == ERROR_SUCCESS;
}

static bool SetDwordValue(const wchar_t *keyPath, const wchar_t *name, UInt32 value)
{
  NRegistry::CKey key;
  if (key.Create(HKEY_CURRENT_USER, keyPath) != ERROR_SUCCESS)
    return false;
  return key.SetValue(name, value) == ERROR_SUCCESS;
}

static bool GetKnownFolder(int csidl, UString &path)
{
  wchar_t buf[kPathBufSize];
  if (::SHGetFolderPathW(NULL, csidl | CSIDL_FLAG_CREATE, NULL, 0, buf) != S_OK)
    return false;
  path = buf;
  return true;
}

static void JoinPath(const UString &folder, const wchar_t *name, UString &res)
{
  res = folder;
  res.Add_PathSepar();
  res += name;
}

/* A .lnk through IShellLink: no ShellExecute, no cmd.exe, nothing that starts an
   interpreter - which is also why this is not done by a script. */
static bool CreateShortcut(const UString &linkPath, const UString &target, const UString &workDir)
{
  CMyComPtr<IShellLinkW> link;
  if (::CoCreateInstance(CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, IID_IShellLinkW,
      (void **)&link) != S_OK)
    return false;
  link->SetPath(target);
  link->SetWorkingDirectory(workDir);
  link->SetDescription(kProduct);
  link->SetIconLocation(target, 0);

  CMyComPtr<IPersistFile> file;
  link.QueryInterface(IID_IPersistFile, (void **)&file);
  if (!file)
    return false;
  return file->Save(linkPath, TRUE) == S_OK;
}

void SetupShortcuts_AskIfNeeded(HWND parent)
{
  if (AlreadyAsked())
    return;

  UString folder;
  if (!GetOwnFolder(folder) || folder.IsEmpty())
    return;

  /* A copy started from a temporary folder is not an installation: a shortcut and an
     uninstall entry for it would point at a folder Windows deletes. Those runs stay quiet,
     and they do not answer the question either. */
  {
    wchar_t tempBuf[kPathBufSize];
    const DWORD n = ::GetTempPathW(kPathBufSize, tempBuf);
    if (n > 0 && n < kPathBufSize)
    {
      UString tempDir = tempBuf;
      while (!tempDir.IsEmpty() && (tempDir.Back() == L'\\' || tempDir.Back() == L'/'))
        tempDir.DeleteBack();
      if (!tempDir.IsEmpty() && folder.Len() >= tempDir.Len() &&
          ::_wcsnicmp((const wchar_t *)folder, (const wchar_t *)tempDir, tempDir.Len()) == 0)
        return;
    }
  }

  UString question = PasswordVault_GetText(IDT_PASSWORD_FIRST_RUN_Q,
      L"要在开始菜单和桌面上创建快捷方式，并在「应用和功能」里登记卸载入口吗？\n\n"
      L"只写入当前用户，不需要管理员权限；不创建也可以照常使用。");
  question.Replace(UString(L"{0}"), folder);

  const int answer = ::MessageBoxW(parent, question, PasswordVault_GetCaption(),
      MB_ICONQUESTION | MB_YESNO);

  /* Asked once, whatever the answer: a user who says no is not asked again on every start.
     The settings page and install.cmd remain available for doing it later by hand. */
  MarkAsked();

  if (answer != IDYES)
    return;

  UString exePath, cmdPath;
  JoinPath(folder, kFmExe, exePath);
  JoinPath(folder, kUninstallCmd, cmdPath);

  bool ok = true;

  UString linkName = kProduct;
  linkName += L".lnk";

  {
    UString dir;
    if (GetKnownFolder(CSIDL_PROGRAMS, dir))
    {
      UString link;
      JoinPath(dir, linkName, link);
      if (!CreateShortcut(link, exePath, folder))
        ok = false;
    }
    else
      ok = false;
  }
  {
    UString dir;
    if (GetKnownFolder(CSIDL_DESKTOPDIRECTORY, dir))
    {
      UString link;
      JoinPath(dir, linkName, link);
      if (!CreateShortcut(link, exePath, folder))
        ok = false;
    }
    else
      ok = false;
  }

  {
    SYSTEMTIME st;
    ::GetLocalTime(&st);
    wchar_t date[16];
    ::wsprintfW(date, L"%04u%02u%02u", (unsigned)st.wYear, (unsigned)st.wMonth, (unsigned)st.wDay);

    UString quiet;
    quiet = L"\""; quiet += cmdPath; quiet += L"\" -KeepVault -Yes -NoBackup";
    UString plain;
    plain = L"\""; plain += cmdPath; plain += L"\"";

    if (!SetStringValue(kUninstallKeyPath, L"DisplayName", UString(kDisplayName)))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"DisplayVersion", UString(kDisplayVer)))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"Publisher", UString(kPublisher)))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"DisplayIcon", exePath))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"InstallLocation", folder))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"UninstallString", plain))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"QuietUninstallString", quiet))
      ok = false;
    if (!SetStringValue(kUninstallKeyPath, L"InstallDate", UString(date)))
      ok = false;
    /* The uninstaller is a script that the user can read, not an MSI: Windows must not offer
       "modify" and "repair" buttons that would do nothing. */
    if (!SetDwordValue(kUninstallKeyPath, L"NoModify", 1))
      ok = false;
    if (!SetDwordValue(kUninstallKeyPath, L"NoRepair", 1))
      ok = false;
  }

  UString message;
  if (ok)
  {
    message = PasswordVault_GetText(IDT_PASSWORD_FIRST_RUN_OK,
        L"已创建快捷方式（开始菜单、桌面），并在「应用和功能」里登记了卸载入口。\n\n{0}");
  }
  else
  {
    message = PasswordVault_GetText(IDT_PASSWORD_FIRST_RUN_FAILED,
        L"没能创建全部快捷方式或登记项（可能被系统策略拦住了）。\n\n"
        L"程序本身不受影响，直接运行这个文件夹里的 7zFM.exe 即可：\n{0}");
  }
  message.Replace(UString(L"{0}"), folder);
  ::MessageBoxW(parent, message, PasswordVault_GetCaption(), MB_ICONINFORMATION | MB_OK);
}

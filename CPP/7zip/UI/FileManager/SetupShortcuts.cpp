// SetupShortcuts.cpp
//
// The convenient part of "installing" without an installer: a Start Menu shortcut, a desktop
// shortcut and an entry in "Apps & features", created by the program itself.
//
// Why here and not in the package's install script: the self-extracting stub that ships with
// 7-Zip (7z.sfx) cannot run a program after unpacking - measured, it ignores RunProgram and
// InstallPath - and "unpack an archive, then run a script that writes to the registry" is one
// of the shapes that anti-virus engines score as a dropper. Doing it in the program with
// IShellLink and HKCU writes with no script interpreter involved removes both problems.
//
// Everything is per-user: HKEY_CURRENT_USER only, no administrator rights, nothing that the
// uninstaller has to run with elevation.
//
// Registry values (all under HKCU\Software\7-Zip\PasswordVault):
//   SetupAsked      DWORD  the first-start question was answered (yes or no)
//   LastRegistered  SZ     the folder the shortcuts / uninstall entry were registered for
//   MoveAskedFrom   SZ     a "the folder changed" question was asked for this pair ...
//   MoveAskedTo     SZ     ... (from, to) - stored as a pair, because one path is not enough
//                          to remember which move was already declined
//
// Three entry points:
//   SetupShortcuts_AskIfNeeded    - the first start of a fresh copy: ask once, remember
//   SetupShortcuts_CheckLocation  - the folder changed since the registration: ask once per
//                                   move, after quietly removing a dead entry
//   SetupShortcuts_Register       - do it now, no questions (the settings page button)
//
// Deliberate limits (documented as known limitations): a program folder on a removable or
// network drive is never offered automatically (an uninstall entry and shortcuts that break
// when the medium is gone are worse than none), a path that is too long is skipped for the
// same reason, and a folder that cannot write its settings is asked about - not asked at all,
// because an answer that cannot be remembered would be asked again on every start.

#include "StdAfx.h"
#include "SetupShortcuts.h"

#include "PasswordVault.h"
#include "PasswordDialogRes.h"

#include "../../../Windows/Registry.h"
#include "../../../Windows/FileFind.h"
#include "../../../Common/MyCom.h"
#include "../../../../C/7zVersion.h"   // MY_VERSION_NUMBERS: the version shown in the entry

#include <shlobj.h>
#include <shellapi.h>

using namespace NWindows;

static const wchar_t * const kKeyPath = L"Software\\7-Zip\\PasswordVault";
static const wchar_t * const kAskedValue = L"SetupAsked";
static const wchar_t * const kRegisteredValue = L"LastRegistered";
static const wchar_t * const kMoveFromValue = L"MoveAskedFrom";
static const wchar_t * const kMoveToValue = L"MoveAskedTo";

static const wchar_t * const kUninstallKeyPath =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\7ZipPasswordVault";
static const wchar_t * const kUninstallParentPath =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";

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
/* A longer install path is not offered a registration: the uninstall string and the icon path
   both end up in the registry, and Windows shortens neither. */
static const unsigned kMaxFolderLen = 200;

static bool CaseInsensitiveEqual(const UString &a, const UString &b)
{
  if (a.Len() != b.Len())
    return false;
  return ::_wcsnicmp((const wchar_t *)a, (const wchar_t *)b, a.Len()) == 0;
}

/* One spelling for a folder: no \\?\ prefix, no trailing separator, no trailing spaces. The
   value is written and compared in this form, and installer\install.ps1 is expected to store
   the same shape. */
static void NormalizeFolder(UString &folder)
{
  /* "\\?\C:\dir" and "\\?\UNC\server\share" are the long-path spellings of the same folders;
     everything recorded and compared here uses the plain form. */
  if (folder.Len() > 4 && wcsncmp((const wchar_t *)folder, L"\\\\?\\", 4) == 0)
  {
    if (folder.Len() > 8 && ::_wcsnicmp((const wchar_t *)folder + 4, L"UNC\\", 4) == 0)
    {
      UString fixed;
      fixed += L"\\\\";
      fixed += UString((const wchar_t *)folder + 8);
      folder = fixed;
    }
    else
    {
      folder.SetFrom((const wchar_t *)folder + 4, folder.Len() - 4);
    }
  }
  while (!folder.IsEmpty())
  {
    const wchar_t c = folder.Back();
    if (c == L'\\' || c == L'/' || c == L' ')
      folder.DeleteBack();
    else
      break;
  }
}

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
  folder.SetFrom(buf, i - 1);   /* without the separator */
  NormalizeFolder(folder);
  return true;
}

static void JoinPath(const UString &folder, const wchar_t *name, UString &res)
{
  res = folder;
  res.Add_PathSepar();
  res += name;
}

static bool FileExists(const UString &path)
{
  return NWindows::NFile::NFind::DoesFileExist_FollowLink((const wchar_t *)path);
}

static bool GetStringValue(const wchar_t *name, UString &value)
{
  value.Empty();
  NRegistry::CKey key;
  if (key.Open(HKEY_CURRENT_USER, kKeyPath) != ERROR_SUCCESS)
    return false;
  /* A value of the wrong type (a DWORD written by an older build or by hand) must not be read
     as text: QueryValue clears the string and reports the type error, which is what makes the
     caller treat it as "nothing recorded" - and that is exactly what should happen. */
  UInt32 asNumber = 0;
  if (key.GetValue_UInt32_IfOk(name, asNumber) == ERROR_SUCCESS)
    return false;
  CSysString text;
  if (key.QueryValue(name, text) != ERROR_SUCCESS)
    return false;
  value = text;
  return true;
}

static bool SetStringValue(const wchar_t *name, const UString &value)
{
  NRegistry::CKey key;
  if (key.Create(HKEY_CURRENT_USER, kKeyPath) != ERROR_SUCCESS)
    return false;
  return key.SetValue(name, (LPCWSTR)value) == ERROR_SUCCESS;
}

static void DeleteValue(const wchar_t *name)
{
  NRegistry::CKey key;
  if (key.Open(HKEY_CURRENT_USER, kKeyPath) == ERROR_SUCCESS)
    key.DeleteValue(name);
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

/* Returns false when the answer could not be stored - the caller must then not ask at all,
   because a question that cannot be remembered is asked again on every start. */
static bool MarkAsked()
{
  NRegistry::CKey key;
  if (key.Create(HKEY_CURRENT_USER, kKeyPath) != ERROR_SUCCESS)
    return false;
  return key.SetValue(kAskedValue, (UInt32)1) == ERROR_SUCCESS;
}

static bool GetKnownFolder(int csidl, UString &path)
{
  wchar_t buf[kPathBufSize];
  if (::SHGetFolderPathW(NULL, csidl | CSIDL_FLAG_CREATE, NULL, 0, buf) != S_OK)
    return false;
  path = buf;
  return true;
}

/* A copy started from a temporary folder is not an installation: a shortcut and an uninstall
   entry for it would point at a folder Windows deletes. */
static bool RunningFromTempFolder(const UString &folder)
{
  wchar_t tempBuf[kPathBufSize];
  const DWORD n = ::GetTempPathW(kPathBufSize, tempBuf);
  if (n == 0 || n >= kPathBufSize)
    return false;
  UString tempDir = tempBuf;
  NormalizeFolder(tempDir);
  if (tempDir.IsEmpty() || folder.Len() < tempDir.Len())
    return false;
  return ::_wcsnicmp((const wchar_t *)folder, (const wchar_t *)tempDir, tempDir.Len()) == 0;
}

/* An uninstall entry and shortcuts for a USB stick or a network share break as soon as the
   medium is gone, and Windows would keep showing an entry that cannot uninstall anything. */
static bool OnRemovableOrNetworkDrive(const UString &folder)
{
  if (folder.Len() < 3 || folder[1] != L':')
    return true;   /* a UNC path or something odd: not a place to register from */
  UString root;
  root += folder[0];
  root += L':';
  root += L'\\';
  const UINT type = ::GetDriveTypeW((const wchar_t *)root);
  return type == DRIVE_REMOVABLE || type == DRIVE_REMOTE || type == DRIVE_CDROM
      || type == DRIVE_NO_ROOT_DIR || type == DRIVE_UNKNOWN;
}

static bool FolderIsSuitable(const UString &folder)
{
  if (folder.IsEmpty() || folder.Len() > kMaxFolderLen)
    return false;
  if (RunningFromTempFolder(folder) || OnRemovableOrNetworkDrive(folder))
    return false;
  return true;
}

/* A shortcut with our name: its target tells whether it belongs to this copy, to another copy
   that is still installed, or to nothing at all. */
static bool ShortcutTarget(const UString &linkPath, UString &target)
{
  target.Empty();
  if (!FileExists(linkPath))
    return false;
  CMyComPtr<IShellLinkW> link;
  if (::CoCreateInstance(CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, IID_IShellLinkW,
      (void **)&link) != S_OK)
    return false;
  CMyComPtr<IPersistFile> file;
  link.QueryInterface(IID_IPersistFile, (void **)&file);
  if (!file)
    return false;
  if (file->Load(linkPath, STGM_READ) != S_OK)
    return false;
  wchar_t buf[kPathBufSize];
  if (link->GetPath(buf, kPathBufSize, NULL, SLGP_RAWPATH) != S_OK)
    return false;
  target = buf;
  return !target.IsEmpty();
}

static bool CreateShortcut(const UString &linkPath, const UString &target, const UString &workDir)
{
  CMyComPtr<IShellLinkW> link;
  if (::CoCreateInstance(CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, IID_IShellLinkW,
      (void **)&link) != S_OK)
    return false;
  if (link->SetPath(target) != S_OK)
    return false;
  link->SetWorkingDirectory(workDir);
  link->SetDescription(kProduct);
  link->SetIconLocation(target, 0);

  CMyComPtr<IPersistFile> file;
  link.QueryInterface(IID_IPersistFile, (void **)&file);
  if (!file)
    return false;
  return file->Save(linkPath, TRUE) == S_OK;
}

/* Creates one shortcut unless another copy of the program is using that name: overwriting it
   would silently take the shortcut away from an installation that still exists. */
static bool CreateShortcutChecked(const UString &linkPath, const UString &exePath,
    const UString &folder, UString &otherCopy)
{
  UString existing;
  if (ShortcutTarget(linkPath, existing))
  {
    UString existingFolder;
    const int pos = existing.ReverseFind_PathSepar();
    if (pos > 0)
      existingFolder.SetFrom((const wchar_t *)existing, (unsigned)pos);
    NormalizeFolder(existingFolder);
    if (!CaseInsensitiveEqual(existingFolder, folder) && FileExists(existing))
    {
      if (otherCopy.IsEmpty())
        otherCopy = existingFolder;
      return true;   /* left alone, and not a failure of this registration */
    }
  }
  return CreateShortcut(linkPath, exePath, folder);
}

/* Writes the shortcuts and the "Apps & features" entry for one folder.
   otherCopy receives the folder of another copy that owns a shortcut with our name.
   entryWritten tells whether the uninstall entry - the part that makes the registration
   meaningful - was really written; only then does the caller record the folder. */
static bool RegisterForFolder(const UString &folder, UString &otherCopy, bool &entryWritten)
{
  otherCopy.Empty();
  entryWritten = false;

  UString exePath, cmdPath;
  JoinPath(folder, kFmExe, exePath);
  JoinPath(folder, kUninstallCmd, cmdPath);

  bool linksOk = true;
  UString linkName = kProduct;
  linkName += L".lnk";

  /* The uninstall entry is a single per-user key: when it already belongs to another
     installation that still exists, writing here would take that installation's entry away.
     That is refused instead of done silently - the caller reports it. */
  {
    UString entryLocation;
    NRegistry::CKey existingKey;
    if (existingKey.Open(HKEY_CURRENT_USER, kUninstallKeyPath) == ERROR_SUCCESS)
    {
      CSysString text;
      if (existingKey.QueryValue(L"InstallLocation", text) == ERROR_SUCCESS)
      {
        entryLocation = text;
        NormalizeFolder(entryLocation);
      }
    }
    if (!entryLocation.IsEmpty() && !CaseInsensitiveEqual(entryLocation, folder))
    {
      UString otherExe;
      JoinPath(entryLocation, kFmExe, otherExe);
      if (FileExists(otherExe))
      {
        otherCopy = entryLocation;
        entryWritten = false;
        return false;
      }
    }
  }

  {
    UString dir;
    if (GetKnownFolder(CSIDL_PROGRAMS, dir))
    {
      UString link;
      JoinPath(dir, linkName, link);
      if (!CreateShortcutChecked(link, exePath, folder, otherCopy))
        linksOk = false;
    }
    else
      linksOk = false;
  }
  {
    UString dir;
    if (GetKnownFolder(CSIDL_DESKTOPDIRECTORY, dir))
    {
      UString link;
      JoinPath(dir, linkName, link);
      if (!CreateShortcutChecked(link, exePath, folder, otherCopy))
        linksOk = false;
    }
    else
      linksOk = false;
  }

  bool regOk = true;
  {
    NRegistry::CKey key;
    if (key.Create(HKEY_CURRENT_USER, kUninstallKeyPath) != ERROR_SUCCESS)
      regOk = false;
    else
    {
      SYSTEMTIME st;
      ::GetLocalTime(&st);
      wchar_t date[16];
      ::wsprintfW(date, L"%04u%02u%02u", (unsigned)st.wYear, (unsigned)st.wMonth, (unsigned)st.wDay);

      UString quiet, plain;
      quiet = L"\""; quiet += cmdPath; quiet += L"\" -KeepVault -Yes -NoBackup";
      plain = L"\""; plain += cmdPath; plain += L"\"";

      struct { const wchar_t *name; const wchar_t *value; } const strings[] =
      {
        { L"DisplayName", kDisplayName },
        { L"DisplayVersion", kDisplayVer },
        { L"Publisher", kPublisher },
        { L"DisplayIcon", (const wchar_t *)exePath },
        { L"InstallLocation", (const wchar_t *)folder },
        { L"UninstallString", (const wchar_t *)plain },
        { L"QuietUninstallString", (const wchar_t *)quiet },
        { L"InstallDate", date }
      };
      for (unsigned i = 0; i < (unsigned)(sizeof(strings) / sizeof(strings[0])); i++)
        if (key.SetValue(strings[i].name, strings[i].value) != ERROR_SUCCESS)
          regOk = false;
      /* The uninstaller is a script the user can read, not an MSI: Windows must not offer
         "modify" and "repair" buttons that would do nothing. */
      if (key.SetValue(L"NoModify", (UInt32)1) != ERROR_SUCCESS)
        regOk = false;
      if (key.SetValue(L"NoRepair", (UInt32)1) != ERROR_SUCCESS)
        regOk = false;
    }
  }

  entryWritten = regOk;
  if (regOk)
    SetStringValue(kRegisteredValue, folder);

  return regOk && linksOk;
}

static void ShowResult(HWND parent, bool ok, const UString &folder, const UString &otherCopy)
{
  if (!otherCopy.IsEmpty())
  {
    UString message = PasswordVault_GetText(IDT_PASSWORD_SHORTCUT_OTHER_COPY,
        L"另一份拷贝或安装仍在使用这个名称或登记，没有改动它：\n\n{0}\n\n"
        L"要让它改指向本目录，请先删除那份拷贝，或删掉它登记的快捷方式 / 卸载项。");
    message.Replace(UString(L"{0}"), otherCopy);
    ::MessageBoxW(parent, message, PasswordVault_GetCaption(), MB_ICONINFORMATION | MB_OK);
    return;
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

bool SetupShortcuts_Register(HWND parent, bool showResult)
{
  UString folder;
  if (!GetOwnFolder(folder) || folder.IsEmpty())
    return false;
  UString otherCopy;
  bool entryWritten = false;
  const bool ok = RegisterForFolder(folder, otherCopy, entryWritten);
  if (showResult)
    ShowResult(parent, ok, folder, otherCopy);
  return ok;
}

void SetupShortcuts_AskIfNeeded(HWND parent)
{
  if (AlreadyAsked())
    return;

  UString folder;
  if (!GetOwnFolder(folder) || !FolderIsSuitable(folder))
    return;

  /* The answer is stored before the question is shown: when it cannot be stored, asking would
     mean asking again on every start, which is worse than not offering the shortcuts. */
  if (!MarkAsked())
    return;

  UString question = PasswordVault_GetText(IDT_PASSWORD_FIRST_RUN_Q,
      L"要在开始菜单和桌面上创建快捷方式，并在「应用和功能」里登记卸载入口吗？\n\n"
      L"只写入当前用户，不需要管理员权限；不创建也可以照常使用。");
  question.Replace(UString(L"{0}"), folder);

  if (::MessageBoxW(parent, question, PasswordVault_GetCaption(),
      MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  UString otherCopy;
  bool entryWritten = false;
  ShowResult(parent, RegisterForFolder(folder, otherCopy, entryWritten), folder, otherCopy);
}

void SetupShortcuts_CheckLocation(HWND parent)
{
  UString folder;
  if (!GetOwnFolder(folder) || folder.IsEmpty())
    return;
  /* The same limits as the first-start question: registering (or re-registering) from a
     removable or network drive, from a temporary folder or from a path that is too long is
     not offered - and a dead entry is not silently cleaned up from such a place either. */
  if (!FolderIsSuitable(folder))
    return;

  UString registered;
  if (!GetStringValue(kRegisteredValue, registered))
    return;
  NormalizeFolder(registered);
  if (registered.IsEmpty() || CaseInsensitiveEqual(registered, folder))
    return;   /* nothing was registered, or it is about this folder */

  /* The registered folder may still be alive: then this is a *copy* of the program, not a
     moved one, and another installation owns the shortcuts and the uninstall entry. Taking
     them over would break that installation, so the copy stays quiet (the settings page has a
     button for a deliberate takeover). Nothing is recorded as "asked" here: when that other
     copy is deleted later, this one has to notice it and offer the registration again. */
  UString registeredExe;
  JoinPath(registered, kFmExe, registeredExe);
  if (FileExists(registeredExe))
    return;

  /* The folder is gone. A dead entry in "Apps & features" cannot uninstall anything and no
     user can use it, so it is removed - but only after checking that it really points at that
     folder, so an entry of another installation is never touched. */
  UString entryLocation;
  {
    NRegistry::CKey key;
    if (key.Open(HKEY_CURRENT_USER, kUninstallKeyPath) == ERROR_SUCCESS)
    {
      CSysString text;
      if (key.QueryValue(L"InstallLocation", text) == ERROR_SUCCESS)
      {
        entryLocation = text;
        NormalizeFolder(entryLocation);
      }
    }
  }

  if (entryLocation.IsEmpty() || CaseInsensitiveEqual(entryLocation, registered))
  {
    NRegistry::CKey parent;
    bool removed = false;
    if (parent.Open(HKEY_CURRENT_USER, kUninstallParentPath) == ERROR_SUCCESS)
    {
      const LONG res = parent.DeleteSubKey(L"7ZipPasswordVault");
      removed = (res == ERROR_SUCCESS || res == ERROR_FILE_NOT_FOUND);
    }
    else
    {
      /* Without access to the key nothing can be cleaned up, and without cleanup the record
         has to stay so that the next start tries again. */
      return;
    }
    if (!removed)
      return;
  }

  /* Nothing is registered for that folder any more. */
  DeleteValue(kRegisteredValue);

  /* The program was moved (or its old folder was deleted): the shortcuts and the uninstall
     entry belong to the old place. Ask once per move - a "no" is an answer and is remembered
     as this (from, to) pair, so the question does not come back on every start. */
  UString from, to;
  if (GetStringValue(kMoveFromValue, from) && GetStringValue(kMoveToValue, to))
  {
    NormalizeFolder(from);
    NormalizeFolder(to);
    if (CaseInsensitiveEqual(from, registered) && CaseInsensitiveEqual(to, folder))
      return;
  }

  SetStringValue(kMoveFromValue, registered);
  SetStringValue(kMoveToValue, folder);

  UString question = PasswordVault_GetText(IDT_PASSWORD_MOVED_ASK,
      L"程序所在文件夹看起来变了：\n\n原来登记在：{0}\n现在运行在：{1}\n\n"
      L"要把快捷方式与「应用和功能」里的卸载登记更新到当前位置吗？");
  question.Replace(UString(L"{0}"), registered);
  question.Replace(UString(L"{1}"), folder);

  if (::MessageBoxW(parent, question, PasswordVault_GetCaption(),
      MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  UString otherCopy;
  bool entryWritten = false;
  ShowResult(parent, RegisterForFolder(folder, otherCopy, entryWritten), folder, otherCopy);
}


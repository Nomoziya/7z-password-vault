// PasswordVault.cpp

#include "StdAfx.h"

#include <wincrypt.h>
#include <dpapi.h>
#include <bcrypt.h>

#include "../../../Windows/FileIO.h"
#include "../../../Windows/ErrorMsg.h"

#include "../Common/ZipRegistry.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "PasswordVault.h"

using namespace NWindows;
using namespace NFile;
using namespace NIO;

static const char kMagic[4] = { '7', 'Z', 'P', 'V' };
static const wchar_t * const kDefaultFileName = L"7zPasswordVault.dat";
/* Version 2: DPAPI mode stored entry names in clear.
   Version 3: DPAPI mode encrypts the names too. Version 2 files are still read. */
static const Byte kVersion = 3;
static const Byte kVersion_Min = 2;

static const unsigned kSaltSize = 16;
static const unsigned kIvSize = 12;
static const unsigned kTagSize = 16;
static const unsigned kKeySize = 32;
static const UInt32 kPbkdf2Iterations = 200000;

/* Sanity limits used when reading the vault file. They protect against a
   corrupted / malicious file that claims huge sizes and would make us
   allocate gigabytes or spin for hours in the key derivation. */
static const UInt32 kMaxNameBytes = 1 << 16;      /* 64 KB */
static const UInt32 kMaxBlobSize  = 1 << 20;      /* 1 MB  */
static const UInt32 kMaxCipherSize = 1 << 24;     /* 16 MB */
static const UInt32 kMinIterations = 1000;
static const UInt32 kMaxIterations = 10000000;
static const UInt32 kMaxEntries = 100000;

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

UString PasswordVault_GetCaption()
{
  return PasswordVault_GetText(IDT_PASSWORD_VAULT_CAPTION, L"7-Zip 密码管家");
}

/* Every error message below is shown in a message box, so it goes through the
   lang files too; the Chinese text stays as the built-in fallback. */
static void SetError(UString &errorMessage, UInt32 langID, const wchar_t *fallback)
{
  errorMessage = PasswordVault_GetText(langID, fallback);
}

// ---------------------------------------------------------------------------
// master password session cache

static UString g_MasterPassword;
static bool g_HaveMasterPassword = false;
static DWORD g_MasterPasswordTick = 0;

/* After this much idle time the cached master password is dropped and the
   user has to type it again. (DWORD milliseconds; the subtraction below is
   wrap-safe, so the ~49 day tick wraparound is not a problem.) */
static const DWORD kMasterIdleMs = 5 * 60 * 1000;

/* Best-effort overwrite of a memory buffer. The compiler is not allowed to
   optimize this away (volatile pointer). */
static void SecureWipe(void *data, size_t size)
{
  if (!data || size == 0)
    return;
  volatile Byte *p = (volatile Byte *)data;
  while (size-- != 0)
    *p++ = 0;
}

static void SecureWipeString(UString &s)
{
  if (!s.IsEmpty())
    SecureWipe(s.Ptr_non_const(), (size_t)s.Len() * sizeof(wchar_t));
  s.Empty();
}

void CPasswordVault::SetCachedMasterPassword(const UString &password)
{
  SecureWipeString(g_MasterPassword);
  g_MasterPassword = password;
  g_HaveMasterPassword = true;
  g_MasterPasswordTick = ::GetTickCount();
}

void CPasswordVault::ClearCachedMasterPassword()
{
  SecureWipeString(g_MasterPassword);
  g_HaveMasterPassword = false;
  g_MasterPasswordTick = 0;
}

bool CPasswordVault::HaveCachedMasterPassword()
{
  return g_HaveMasterPassword;
}

// ---------------------------------------------------------------------------
// helpers

static UString GetVaultFolderPath()
{
  UString folder;
  wchar_t buf[300];
  const DWORD len = GetEnvironmentVariableW(L"APPDATA", buf, 300);
  if (len != 0 && len < 300)
    folder.SetFrom(buf, (unsigned)len);
  else
    folder = L".";
  folder += L"\\7-Zip";
  return folder;
}

UString PasswordVault_NormalizePath(const UString &path)
{
  UString p = path;
  p.Trim();
  if (p.Len() >= 2 && p[0] == L'"' && p.Back() == L'"')
  {
    p.Delete(0);
    p.DeleteBack();
    p.Trim();
  }
  if (p.IsEmpty())
    return p;

  bool isFolder = false;
  const DWORD attr = ::GetFileAttributesW(p);
  if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) != 0)
    isFolder = true;
  else if (IS_PATH_SEPAR(p.Back()))
    isFolder = true;

  if (!isFolder)
    return p;

  if (!IS_PATH_SEPAR(p.Back()))
    p.Add_PathSepar();
  p += kDefaultFileName;
  return p;
}

/* An error that carries the path, and the system message when a single Win32 call
   failed: "cannot replace the vault file" on its own tells the user nothing about
   what to fix. The system text comes localized from Windows. */
static void SetPathError(UString &errorMessage, UInt32 langID, const wchar_t *fallback,
    const UString &path, DWORD sysError)
{
  UString s = PasswordVault_GetText(langID, fallback);
  s.Replace(UString(L"{0}"), path);
  if (sysError != 0)
  {
    UString sys = NError::MyFormatMessage(sysError);
    sys.Trim();
    s.Replace(UString(L"{1}"), sys);
  }
  else
    s.Replace(UString(L"{1}"), UString());
  errorMessage = s;
}

/* The folder the running program sits in: both 7zFM and 7zG use this, so the
   vault can live next to the executable instead of on the system drive. */
static UString GetProgramFolderPath()
{
  wchar_t buf[MAX_PATH + 1];
  const DWORD len = ::GetModuleFileNameW(NULL, buf, MAX_PATH);
  if (len == 0 || len >= MAX_PATH)
    return UString();
  UString path;
  path.SetFrom(buf, (unsigned)len);
  const int pos = path.ReverseFind_PathSepar();
  if (pos < 0)
    return UString();
  return path.Left((unsigned)pos);
}

/* Can a file be created in this folder? A program folder under Program Files cannot,
   and then the vault has to stay in %APPDATA% instead of failing on every save. */
static bool CanWriteToFolder(const UString &folder)
{
  if (folder.IsEmpty())
    return false;
  UString probe = folder;
  probe.Add_PathSepar();
  probe += kDefaultFileName;
  probe += L".writetest";
  /* a per process name: two processes (7zFM and 7zG) probing at the same moment would
     otherwise see each other's file and both conclude "not writable" */
  {
    UString pid;
    pid.Add_UInt32((UInt32)::GetCurrentProcessId());
    probe += L".";
    probe += pid;
  }
  /* FILE_FLAG_DELETE_ON_CLOSE: the probe removes itself when the handle is closed. */
  HANDLE h = ::CreateFileW(probe, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
      FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  ::CloseHandle(h);
  return true;
}

static bool FileSizeMatches(const UString &path, const ULARGE_INTEGER &expected)
{
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!::GetFileAttributesExW(path, GetFileExInfoStandard, &data))
    return false;
  ULARGE_INTEGER actual;
  actual.LowPart = data.nFileSizeLow;
  actual.HighPart = data.nFileSizeHigh;
  return actual.QuadPart == expected.QuadPart;
}

static void EnsureFolderExists(const UString &filePath)
{
  const int pos = filePath.ReverseFind_PathSepar();
  if (pos <= 0)
    return;

  const UString dir = filePath.Left((unsigned)pos);

  /* For a path like "D:\file.dat" dir is "D:". That is a drive-relative path,
     not a directory, and CreateDirectoryW would fail on it. The drive root
     always exists, so nothing has to be created. */
  const wchar_t *p = dir.Ptr();
  if (dir.Len() == 2 && p[1] == L':')
    return;

  ::CreateDirectoryW(dir, NULL);
}

static bool WriteBuf(COutFile &f, const void *data, size_t size)
{
  return f.WriteFull(data, size);
}

static bool ReadBuf(CInFile &f, void *data, size_t size)
{
  size_t processed = 0;
  return f.ReadFull(data, size, processed) && processed == size;
}

static bool WriteUInt32(COutFile &f, UInt32 v)
{
  return WriteBuf(f, &v, 4);
}

static bool ReadUInt32(CInFile &f, UInt32 &v)
{
  return ReadBuf(f, &v, 4);
}

static void AppendBuf(CByteBuffer &b, const void *data, size_t size)
{
  const size_t pos = b.Size();
  b.ChangeSize_KeepData(pos + size, pos);
  if (size != 0)
    memcpy((Byte *)b + pos, data, size);
}

static void AppendUInt32(CByteBuffer &b, UInt32 v)
{
  AppendBuf(b, &v, 4);
}

static bool ReadBufMem(const Byte *data, size_t size, size_t &pos, void *out, size_t n)
{
  if (pos + n > size)
    return false;
  if (n != 0)
    memcpy(out, data + pos, n);
  pos += n;
  return true;
}

static bool ReadUInt32Mem(const Byte *data, size_t size, size_t &pos, UInt32 &v)
{
  return ReadBufMem(data, size, pos, &v, 4);
}

// ---------------------------------------------------------------------------
// DPAPI

static bool DpapiProtect(const void *data, size_t size, CByteBuffer &out)
{
  DATA_BLOB in, res;
  in.pbData = (BYTE *)(void *)data;
  in.cbData = (DWORD)size;
  res.pbData = NULL;
  res.cbData = 0;
  if (!CryptProtectData(&in, L"7-Zip Password Vault", NULL, NULL, NULL, 0, &res))
    return false;
  out.CopyFrom((const Byte *)res.pbData, (size_t)res.cbData);
  LocalFree(res.pbData);
  return true;
}

static bool DpapiUnprotect(const void *data, size_t size, CByteBuffer &out)
{
  DATA_BLOB in, res;
  in.pbData = (BYTE *)(void *)data;
  in.cbData = (DWORD)size;
  res.pbData = NULL;
  res.cbData = 0;
  if (!CryptUnprotectData(&in, NULL, NULL, NULL, NULL, 0, &res))
    return false;
  out.CopyFrom((const Byte *)res.pbData, (size_t)res.cbData);
  memset(res.pbData, 0, res.cbData);
  LocalFree(res.pbData);
  return true;
}

// ---------------------------------------------------------------------------
// CNG (bcrypt) : PBKDF2-HMAC-SHA256 + AES-256-GCM

static bool GenRandom(Byte *buf, size_t size)
{
  return BCryptGenRandom(NULL, buf, (ULONG)size, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
}

static bool DeriveKey(const UString &password, const Byte *salt, size_t saltSize, UInt32 iterations, Byte key[kKeySize])
{
  BCRYPT_ALG_HANDLE alg = NULL;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0)
    return false;
  const size_t pwBytes = (size_t)password.Len() * sizeof(wchar_t);
  const bool ok =
    BCryptDeriveKeyPBKDF2(alg,
        (PUCHAR)(const void *)(const wchar_t *)password, (ULONG)pwBytes,
        (PUCHAR)salt, (ULONG)saltSize,
        iterations, key, kKeySize, 0) == 0;
  BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

static bool AesGcm(bool encrypt,
    const Byte key[kKeySize], const Byte *iv, unsigned ivSize,
    const Byte *in, unsigned inSize, Byte *out, Byte *tag, unsigned tagSize)
{
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_KEY_HANDLE hKey = NULL;
  bool ok = false;

  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, NULL, 0) != 0)
    return false;
  if (BCryptSetProperty(alg, BCRYPT_CHAINING_MODE,
      (PUCHAR)BCRYPT_CHAIN_MODE_GCM, sizeof(BCRYPT_CHAIN_MODE_GCM), 0) != 0)
    goto end;
  if (BCryptGenerateSymmetricKey(alg, &hKey, NULL, 0, (PUCHAR)key, kKeySize, 0) != 0)
    goto end;

  {
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = (PUCHAR)iv;
    info.cbNonce = ivSize;
    info.pbTag = tag;
    info.cbTag = tagSize;

    ULONG outLen = 0;
    const NTSTATUS st = encrypt
      ? BCryptEncrypt(hKey, (PUCHAR)in, inSize, &info, NULL, 0, out, inSize, &outLen, 0)
      : BCryptDecrypt(hKey, (PUCHAR)in, inSize, &info, NULL, 0, out, inSize, &outLen, 0);
    ok = (st == 0);
  }

end:
  if (hKey) BCryptDestroyKey(hKey);
  BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

// ---------------------------------------------------------------------------
// master password prompt

class CPasswordMasterDialog: public NWindows::NControl::CModalDialog
{
  NWindows::NControl::CEdit _edit;
  virtual bool OnInit() Z7_override;
  virtual void OnOK() Z7_override;
public:
  UString Password;
  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD_MASTER, parentWindow); }
};

bool CPasswordMasterDialog::OnInit()
{
  #ifdef Z7_LANG
  LangSetWindowText(*this, IDD_PASSWORD_MASTER);
  {
    const UInt32 ids[] = { IDT_PASSWORD_MASTER };
    LangSetDlgItems(*this, ids, Z7_ARRAY_SIZE(ids));
  }
  #endif
  _edit.Attach(GetItem(IDE_PASSWORD_MASTER));
  _edit.SetText(Password);
  return CModalDialog::OnInit();
}

void CPasswordMasterDialog::OnOK()
{
  _edit.GetText(Password);
  CModalDialog::OnOK();
}

bool CPasswordVault::PromptForMasterPassword(HWND parent, UString &password, UString &errorMessage)
{
  CPasswordMasterDialog dialog;
  if (dialog.Create(parent) != IDOK)
  {
    /* The user cancelled. Leave errorMessage empty so that callers can tell
       "cancelled" from a real failure and stay silent about it. */
    errorMessage.Empty();
    return false;
  }
  password = dialog.Password;
  return true;
}

bool CPasswordVault::GetMasterPassword(HWND parent, UString &password, UString &errorMessage)
{
  NPasswordVault::CInfo settings;
  settings.Load();

  if (g_HaveMasterPassword &&
      settings.AutoLockMaster &&
      (DWORD)(::GetTickCount() - g_MasterPasswordTick) > kMasterIdleMs)
  {
    // Idle for too long: drop the cached password and ask for it again.
    ClearCachedMasterPassword();
  }

  if (g_HaveMasterPassword)
  {
    password = g_MasterPassword;
    g_MasterPasswordTick = ::GetTickCount();
    return true;
  }

  if (!PromptForMasterPassword(parent, password, errorMessage))
    return false;

  if (settings.RememberMasterPassword)
    SetCachedMasterPassword(password);

  return true;
}

// ---------------------------------------------------------------------------
// path

UString CPasswordVault::GetDefaultPath()
{
  const UString programFolder = GetProgramFolderPath();
  UString portable;
  if (!programFolder.IsEmpty())
  {
    portable = programFolder;
    portable.Add_PathSepar();
    portable += kDefaultFileName;
  }

  UString roaming = GetVaultFolderPath();
  roaming.Add_PathSepar();
  roaming += kDefaultFileName;

  /* Portable first: the vault sits next to the program. An existing file always
     wins, so a vault in %APPDATA% is never silently replaced or lost. */
  if (!portable.IsEmpty())
  {
    if (::GetFileAttributesW(portable) != INVALID_FILE_ATTRIBUTES)
      return portable;
    if (::GetFileAttributesW(roaming) == INVALID_FILE_ATTRIBUTES && CanWriteToFolder(programFolder))
      return portable;
  }
  return roaming;
}

UString CPasswordVault::AdoptPortableDefault()
{
  /* Nothing configured and the vault still sits in %APPDATA%\7-Zip: move it next to
     the program, which is what the portable default is for. */
  NPasswordVault::CInfo settings;
  settings.Load();
  if (!settings.VaultPath.IsEmpty())
    return UString();   /* the location was chosen by the user - never touch it */

  const UString programFolder = GetProgramFolderPath();
  if (programFolder.IsEmpty() || !CanWriteToFolder(programFolder))
    return UString();

  UString portable = programFolder;
  portable.Add_PathSepar();
  portable += kDefaultFileName;

  UString roaming = GetVaultFolderPath();
  roaming.Add_PathSepar();
  roaming += kDefaultFileName;

  if (::GetFileAttributesW(portable) != INVALID_FILE_ATTRIBUTES)
    return UString();   /* already portable */
  if (::GetFileAttributesW(roaming) == INVALID_FILE_ATTRIBUTES)
    return UString();   /* no old vault to move */

  ULARGE_INTEGER sizeBefore;
  sizeBefore.QuadPart = 0;
  {
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (::GetFileAttributesExW(roaming, GetFileExInfoStandard, &data))
    {
      sizeBefore.LowPart = data.nFileSizeLow;
      sizeBefore.HighPart = data.nFileSizeHigh;
    }
  }
  /* MOVEFILE_COPY_ALLOWED: %APPDATA% and the program folder are often on different
     drives, and without this flag the move simply fails there (the portable default
     then never happens and the user is never told). When it copies, the source is only
     deleted after a successful copy. */
  if (!::MoveFileExW(roaming, portable, MOVEFILE_COPY_ALLOWED))
    return UString();   /* the old location stays in use */

  /* A copy that was interrupted between the copy and the delete would leave a partial
     file at the new place: check it before it is used. */
  if (!FileSizeMatches(portable, sizeBefore))
  {
    ::DeleteFileW(portable);
    return UString();
  }


  /* Persist the new location: the decision must not be re-derived from the file
     system on every start (a second process, a temporarily unwritable folder or a
     stray file would change the answer). */
  settings.VaultPath = us2fs(portable);
  settings.Save();

  UString message = PasswordVault_GetText(IDT_PASSWORD_MOVED_TO_PORTABLE,
      L"密码库文件已移动到程序所在文件夹：\n\n{0}");
  message.Replace(UString(L"{0}"), portable);
  return message;
}

UString CPasswordVault::GetConfiguredPath()
{
  NPasswordVault::CInfo settings;
  settings.Load();
  if (!settings.VaultPath.IsEmpty())
    return PasswordVault_NormalizePath(settings.VaultPath);
  return CPasswordVault::GetDefaultPath();
}

// ---------------------------------------------------------------------------
// load / save

bool CPasswordVault::Load(HWND parent, UString &errorMessage)
{
  _entries.Clear();
  _masterMode = false;
  /* Failed until a load really succeeded: every "return false" below - a bad version,
     a bad header, a decryption or parse failure - then keeps saving disabled without
     having to be listed here. */
  _readFailed = true;
  _loadedSize = 0;
  _loadedWriteTime = 0;

  CInFile f;
  if (!f.Open(_path))
  {
    /* "no file yet" and "cannot open the file" are very different: the first is an
       empty vault, the second (a lock, a permission problem, a read-only volume) used
       to look like an empty vault too - and then the next save wrote that empty list
       over the real file. */
    const DWORD sysError = ::GetLastError();
    if (::GetFileAttributesW(_path) == INVALID_FILE_ATTRIBUTES)
    {
      _readFailed = false; // really does not exist yet: an empty vault, not a failure
      return true;
    }
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, sysError);
    _readFailed = true;
    return false;
  }


  char magic[4];
  if (!ReadBuf(f, magic, 4) || memcmp(magic, kMagic, 4) != 0)
  {
    _readFailed = true;
    SetError(errorMessage, IDT_PASSWORD_ERR_MAGIC, L"密码库文件头无效");
    return false;
  }

  Byte version = 0;
  if (!ReadBuf(f, &version, 1) || version < kVersion_Min || version > kVersion)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_VERSION, L"不支持的密码库版本");
    return false;
  }

  Byte flags = 0;
  if (!ReadBuf(f, &flags, 1))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
    return false;
  }

  _masterMode = ((flags & 1) != 0);
  const bool ok = _masterMode ? Load_Master(parent, f, errorMessage) : Load_DPAPI(f, version, errorMessage);
  if (ok)
  {
    _readFailed = false;
    RememberFileState();
  }
  return ok;
}

void CPasswordVault::RememberFileState()
{
  _loadedSize = 0;
  _loadedWriteTime = 0;
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!::GetFileAttributesExW(_path, GetFileExInfoStandard, &data))
    return;
  _loadedSize = ((unsigned long long)data.nFileSizeHigh << 32) | data.nFileSizeLow;
  _loadedWriteTime = ((unsigned long long)data.ftLastWriteTime.dwHighDateTime << 32) |
      data.ftLastWriteTime.dwLowDateTime;
}

bool CPasswordVault::Save(UString &errorMessage, HWND parent)
{
  if (_readFailed)
  {
    /* Load() could not read the file that is there. Writing now would replace it with
       the empty list in memory - a vault that cannot be opened must never be
       overwritten, no matter which dialog asks for a save. */
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, 0);
    return false;
  }

  EnsureFolderExists(_path);

  /* Write to a temporary file first, then replace the real file atomically.
     Otherwise a crash / power loss in the middle of a write would destroy
     the whole vault (all saved passwords). */
  UString tmpPath = _path + L".tmp";
  {
    /* 7zFM and 7zG can save at the same time: without the process id they would write
       the same temporary file and replace the vault with a half written one. */
    UString pid;
    pid.Add_UInt32((UInt32)::GetCurrentProcessId());
    tmpPath += L".";
    tmpPath += pid;
  }

  {
    COutFile f;
    if (!f.Create_ALWAYS(tmpPath))
    {
      const DWORD sysError = ::GetLastError();
      SetPathError(errorMessage, IDT_PASSWORD_ERR_CREATE, L"无法创建密码库文件：\n{0}\n{1}",
          _path, sysError);
      return false;
    }

    bool ok = WriteBuf(f, kMagic, 4) && WriteBuf(f, &kVersion, 1);

    if (ok)
    {
      NPasswordVault::CInfo settings;
      settings.Load();
      const bool useMaster = settings.UseMasterPassword;
      const Byte flags = useMaster ? 1 : 0;
      ok = WriteBuf(f, &flags, 1);
      if (ok)
        ok = useMaster ? Save_Master(f, errorMessage, parent) : Save_DPAPI(f, errorMessage);
    }

    if (!ok && errorMessage.IsEmpty())
    {
      /* An empty message means the user cancelled the master password prompt: that is
         not a write error and must not be reported as one. */
      f.Close();
      ::DeleteFileW(tmpPath);
      return false;
    }

    f.Close();

    if (!ok)
    {
      ::DeleteFileW(tmpPath);
      return false;
    }
  }

  /* Another process may have saved after this one read the file. Replacing it
     now would silently drop the entries that were added there. */
  {
    WIN32_FILE_ATTRIBUTE_DATA now;
    if (::GetFileAttributesExW(_path, GetFileExInfoStandard, &now))
    {
      const unsigned long long size = ((unsigned long long)now.nFileSizeHigh << 32) | now.nFileSizeLow;
      const unsigned long long when = ((unsigned long long)now.ftLastWriteTime.dwHighDateTime << 32) |
          now.ftLastWriteTime.dwLowDateTime;
      if ((size != _loadedSize || when != _loadedWriteTime) && (_loadedSize != 0 || _loadedWriteTime != 0))
      {
        SetPathError(errorMessage, IDT_PASSWORD_ERR_CHANGED,
            L"密码库已被另一个窗口修改，请重新打开：\n{0}", _path, 0);
        ::DeleteFileW(tmpPath);
        return false;
      }
    }
  }

  if (!::MoveFileExW(tmpPath, _path, MOVEFILE_REPLACE_EXISTING))
  {
    /* The reason is captured before anything else runs: DeleteFileW below would
       overwrite it. */
    const DWORD sysError = ::GetLastError();
    SetPathError(errorMessage, IDT_PASSWORD_ERR_REPLACE, L"无法替换密码库文件：\n{0}\n{1}",
        _path, sysError);
    ::DeleteFileW(tmpPath);
    return false;
  }

  /* What was just written is the state we read now: without this the next save of the
     same instance would compare against the old file and report a conflict. */
  RememberFileState();
  return true;
}

void CPasswordVault::SerializeEntries(CByteBuffer &out)
{
  AppendUInt32(out, (UInt32)_entries.Size());
  FOR_VECTOR(i, _entries)
  {
    const CPasswordVaultEntry &e = _entries[i];
    const UInt32 nameBytes = (UInt32)(e.Name.Len() * 2);
    AppendUInt32(out, nameBytes);
    if (nameBytes != 0)
      AppendBuf(out, (const void *)(const wchar_t *)e.Name, nameBytes);
    const UInt32 passBytes = (UInt32)(e.Password.Len() * 2);
    AppendUInt32(out, passBytes);
    if (passBytes != 0)
      AppendBuf(out, (const void *)(const wchar_t *)e.Password, passBytes);
  }
}

bool CPasswordVault::ParseEntries(const Byte *data, size_t size, UString &errorMessage)
{
  size_t pos = 0;
  UInt32 count = 0;
  if (!ReadUInt32Mem(data, size, pos, count))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
    return false;
  }

  for (UInt32 i = 0; i < count; i++)
  {
    UInt32 nameBytes = 0;
    if (!ReadUInt32Mem(data, size, pos, nameBytes) || (nameBytes & 1) != 0 || pos + nameBytes > size)
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
      return false;
    }

    UString name;
    {
      const unsigned charCount = nameBytes / 2;
      wchar_t *p = name.GetBuf(charCount);
      if (nameBytes != 0)
        memcpy(p, data + pos, nameBytes);
      p[charCount] = 0;
      name.ReleaseBuf_SetLen(charCount);
    }
    pos += nameBytes;

    UInt32 passBytes = 0;
    if (!ReadUInt32Mem(data, size, pos, passBytes) || (passBytes & 1) != 0 || pos + passBytes > size)
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
      return false;
    }

    UString password;
    {
      const unsigned charCount = passBytes / 2;
      wchar_t *p = password.GetBuf(charCount);
      if (passBytes != 0)
        memcpy(p, data + pos, passBytes);
      p[charCount] = 0;
      password.ReleaseBuf_SetLen(charCount);
    }
    pos += passBytes;

    CPasswordVaultEntry entry;
    entry.Name = name;
    entry.Password = password;
    _entries.Add(entry);
  }

  return true;
}

// ---------------------------------------------------------------------------
// DPAPI-mode entry helpers

/* Reads a length-prefixed DPAPI-protected string. */
static bool Read_DPAPI_String(CInFile &f, UString &dest, UString &errorMessage)
{
  UInt32 blobSize = 0;
  if (!ReadUInt32(f, blobSize) || blobSize > kMaxBlobSize)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_ENTRY, L"密码库条目已损坏");
    return false;
  }

  CByteBuffer blob(blobSize);
  if (blobSize != 0 && !ReadBuf(f, blob, blobSize))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_ENTRY, L"密码库条目已损坏");
    return false;
  }

  CByteBuffer plain;
  if (!DpapiUnprotect((const Byte *)blob, blobSize, plain))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_DECRYPT, L"解密失败（可能不是同一个 Windows 账户或电脑）");
    return false;
  }
  if ((plain.Size() & 1) != 0)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_PASSWORD, L"密码数据无效");
    return false;
  }

  const unsigned charCount = (unsigned)(plain.Size() / 2);
  wchar_t *p = dest.GetBuf(charCount);
  if (plain.Size() != 0)
    memcpy(p, (const Byte *)plain, plain.Size());
  p[charCount] = 0;
  dest.ReleaseBuf_SetLen(charCount);
  plain.Wipe();
  return true;
}

static bool Write_DPAPI_String(COutFile &f, const UString &s, UString &errorMessage)
{
  CByteBuffer blob;
  if (!DpapiProtect((const void *)(const wchar_t *)s, (size_t)s.Len() * sizeof(wchar_t), blob))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_ENCRYPT, L"加密失败");
    return false;
  }
  const UInt32 blobSize = (UInt32)blob.Size();
  if (!WriteUInt32(f, blobSize) || (blobSize != 0 && !WriteBuf(f, (const Byte *)blob, blobSize)))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
    return false;
  }
  return true;
}

/* Reads a length-prefixed UTF-16 string stored in clear (used by vault version 2,
   where DPAPI mode did not encrypt the entry names). */
static bool Read_PlainString(CInFile &f, UString &dest, UString &errorMessage)
{
  UInt32 bytes = 0;
  if (!ReadUInt32(f, bytes) || (bytes & 1) != 0 || bytes > kMaxNameBytes)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_ENTRY, L"密码库条目已损坏");
    return false;
  }

  CByteBuffer buf(bytes);
  if (bytes != 0 && !ReadBuf(f, buf, bytes))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_ENTRY, L"密码库条目已损坏");
    return false;
  }

  const unsigned charCount = bytes / 2;
  wchar_t *p = dest.GetBuf(charCount);
  if (bytes != 0)
    memcpy(p, (const Byte *)buf, bytes);
  p[charCount] = 0;
  dest.ReleaseBuf_SetLen(charCount);
  return true;
}

bool CPasswordVault::Load_DPAPI(CInFile &f, Byte version, UString &errorMessage)
{
  UInt32 count = 0;
  if (!ReadUInt32(f, count) || count > kMaxEntries)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
    return false;
  }

  for (UInt32 i = 0; i < count; i++)
  {
    CPasswordVaultEntry entry;

    /* Version 3 encrypts the names as well; version 2 stored them in clear. */
    const bool nameOk = (version >= 3)
        ? Read_DPAPI_String(f, entry.Name, errorMessage)
        : Read_PlainString(f, entry.Name, errorMessage);
    if (!nameOk)
      return false;

    if (!Read_DPAPI_String(f, entry.Password, errorMessage))
      return false;

    _entries.Add(entry);
  }

  return true;
}

bool CPasswordVault::Load_Master(HWND parent, CInFile &f, UString &errorMessage)
{
  Byte salt[kSaltSize];
  UInt32 iterations = 0;
  Byte iv[kIvSize];
  Byte tag[kTagSize];
  UInt32 cipherLen = 0;

  if (!ReadBuf(f, salt, kSaltSize) || !ReadUInt32(f, iterations) ||
      !ReadBuf(f, iv, kIvSize) || !ReadBuf(f, tag, kTagSize) || !ReadUInt32(f, cipherLen) ||
      iterations < kMinIterations || iterations > kMaxIterations ||
      cipherLen > kMaxCipherSize)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
    return false;
  }

  CByteBuffer cipher(cipherLen);
  if (cipherLen != 0 && !ReadBuf(f, cipher, cipherLen))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
    return false;
  }

  UString master;
  if (!GetMasterPassword(parent, master, errorMessage))
    return false;

  Byte key[kKeySize];
  if (!DeriveKey(master, salt, kSaltSize, iterations, key))
  {
    SecureWipeString(master);
    SetError(errorMessage, IDT_PASSWORD_ERR_KDF, L"密钥派生失败");
    return false;
  }

  CByteBuffer plain(cipherLen);
  const bool decOk = AesGcm(false, key, iv, kIvSize,
      (const Byte *)cipher, cipherLen, (Byte *)plain, tag, kTagSize);
  SecureWipe(key, sizeof(key));
  SecureWipeString(master);
  if (!decOk)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_MASTER, L"主密码错误，或密码库文件已损坏");
    return false;
  }

  if (!ParseEntries((const Byte *)plain, cipherLen, errorMessage))
    return false;

  plain.Wipe();
  return true;
}

bool CPasswordVault::Save_DPAPI(COutFile &f, UString &errorMessage)
{
  const UInt32 count = (UInt32)_entries.Size();
  if (!WriteUInt32(f, count))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
    return false;
  }

  FOR_VECTOR(i, _entries)
  {
    const CPasswordVaultEntry &entry = _entries[i];
    /* Names are encrypted too, so the file does not reveal what the saved
       passwords are used for. */
    if (!Write_DPAPI_String(f, entry.Name, errorMessage))
      return false;
    if (!Write_DPAPI_String(f, entry.Password, errorMessage))
      return false;
  }

  return true;
}

bool CPasswordVault::Save_Master(COutFile &f, UString &errorMessage, HWND parent)
{
  UString master;
  if (!GetMasterPassword(parent, master, errorMessage))
    return false;

  Byte salt[kSaltSize];
  Byte iv[kIvSize];
  if (!GenRandom(salt, kSaltSize) || !GenRandom(iv, kIvSize))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_RANDOM, L"随机数生成失败");
    return false;
  }

  Byte key[kKeySize];
  if (!DeriveKey(master, salt, kSaltSize, kPbkdf2Iterations, key))
  {
    SecureWipeString(master);
    SetError(errorMessage, IDT_PASSWORD_ERR_KDF, L"密钥派生失败");
    return false;
  }
  SecureWipeString(master);

  CByteBuffer plain;
  SerializeEntries(plain);

  CByteBuffer cipher(plain.Size());
  Byte tag[kTagSize];
  const bool encOk = AesGcm(true, key, iv, kIvSize,
      (const Byte *)plain, (unsigned)plain.Size(), (Byte *)cipher, tag, kTagSize);
  SecureWipe(key, sizeof(key));
  plain.Wipe();
  if (!encOk)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_ENCRYPT, L"加密失败");
    return false;
  }

  if (!WriteBuf(f, salt, kSaltSize) ||
      !WriteUInt32(f, kPbkdf2Iterations) ||
      !WriteBuf(f, iv, kIvSize) ||
      !WriteBuf(f, tag, kTagSize) ||
      !WriteUInt32(f, (UInt32)plain.Size()) ||
      !WriteBuf(f, (const Byte *)cipher, plain.Size()))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
    return false;
  }

  plain.Wipe();
  return true;
}

int CPasswordVault::FindByName(const UString &name) const
{
  /* An empty name is not an identifier: several entries may be unnamed, and an
     empty name must never match one of them (otherwise saving an unnamed entry
     would silently overwrite an existing unnamed one). */
  if (name.IsEmpty())
    return -1;
  FOR_VECTOR(i, _entries)
    if (_entries[i].Name == name)
      return (int)i;
  return -1;
}

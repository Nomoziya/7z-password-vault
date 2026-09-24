// PasswordVault.cpp

#include "StdAfx.h"

#include <wincrypt.h>
#include <dpapi.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <aclapi.h>

#include "../../../Windows/FileIO.h"
#include "../../../Windows/ErrorMsg.h"

#include "../Common/ZipRegistry.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "PasswordVault.h"

// Upstream headers target Windows 2000; this fork supports Windows 10/11.
// Keep the older header setting isolated from the rest of the 7-Zip sources.
extern "C" WINBASEAPI DWORD WINAPI GetFinalPathNameByHandleW(HANDLE, LPWSTR, DWORD, DWORD);

using namespace NWindows;
using namespace NFile;
using namespace NIO;

static const char kMagic[4] = { '7', 'Z', 'P', 'V' };
static const wchar_t * const kDefaultFileName = L"7zPasswordVault.dat";
/* Version 2: DPAPI mode stored entry names in clear.
   Version 3: DPAPI mode encrypts the names too. Version 2 files are still read. */
static const Byte kVersion = 4;
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

static CVaultString g_MasterPassword;
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
  if (data && size != 0)
    ::SecureZeroMemory(data, size);
}

static void SecureWipeString(UString &s)
{
  if (!s.IsEmpty())
    SecureWipe(s.Ptr_non_const(), (size_t)s.Len() * sizeof(wchar_t));
  s.Empty();
}

CPasswordVaultEntry &CPasswordVaultEntry::operator=(const CPasswordVaultEntry &other)
{
  if (this != &other)
  {
    SecureWipeString(Name);
    SecureWipeString(Password);
    Name = other.Name;
    Password = other.Password;
  }
  return *this;
}

CPasswordVaultEntry::~CPasswordVaultEntry()
{
  SecureWipeString(Name);
  SecureWipeString(Password);
}

CPasswordVault::~CPasswordVault()
{
  ReleaseSession();
  ClearEntries();
}

void CPasswordVault::ReleaseSession()
{
  if (_session != INVALID_HANDLE_VALUE) ::CloseHandle(_session);
  _session = INVALID_HANDLE_VALUE;
}

void CPasswordVault::ClearEntries()
{
  FOR_VECTOR(i, _entries)
  {
    SecureWipeString(_entries[i].Name);
    SecureWipeString(_entries[i].Password);
  }
  _entries.Clear();
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
  wchar_t buf[MAX_PATH];
  if (FAILED(::SHGetFolderPathW(NULL, CSIDL_APPDATA | CSIDL_FLAG_CREATE,
      NULL, SHGFP_TYPE_CURRENT, buf))) return UString();
  UString folder = buf;
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

// Never follow a vault leaf link. Missing leaves are valid for first save;
// directories, reparse points and ambiguous hard-link aliases are not.
static bool IsSafeVaultLeaf(const UString &path)
{
  const DWORD attributes = ::GetFileAttributesW(path);
  if (attributes == INVALID_FILE_ATTRIBUTES)
  {
    const DWORD error = ::GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
  }
  if (attributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))
  {
    ::SetLastError(ERROR_ACCESS_DENIED);
    return false;
  }
  HANDLE h = ::CreateFileW(path, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (h == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info;
  const BOOL ok = ::GetFileInformationByHandle(h, &info);
  const DWORD error = ::GetLastError();
  ::CloseHandle(h);
  if (!ok) { ::SetLastError(error); return false; }
  if ((info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
      info.nNumberOfLinks > 1)
  {
    ::SetLastError(ERROR_ACCESS_DENIED);
    return false;
  }
  return true;
}

// Real-time file scanners can briefly hold the destination open after a vault
// write. Retry only sharing/access conflicts; each attempt remains one atomic
// replacement, and persistent errors still abort the save without a fallback.
static bool MoveVaultFileWithRetry(const UString &source, const UString &target)
{
  const DWORD flags = MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH;
  for (unsigned attempt = 0; attempt < 40; ++attempt)
  {
    if (!IsSafeVaultLeaf(target)) return false;
    if (::MoveFileExW(source, target, flags)) return true;
    const DWORD error = ::GetLastError();
    if ((error != ERROR_ACCESS_DENIED && error != ERROR_SHARING_VIOLATION) || attempt == 39)
    {
      ::SetLastError(error);
      return false;
    }
    ::Sleep(25);
  }
  ::SetLastError(ERROR_ACCESS_DENIED);
  return false;
}

static UString GetCanonicalVaultPath(const UString &path)
{
  wchar_t full[32768];
  const DWORD n = ::GetFullPathNameW(path, Z7_ARRAY_SIZE(full), full, NULL);
  UString s;
  if (n != 0 && n < Z7_ARRAY_SIZE(full))
    s.SetFrom(full, (unsigned)n);
  else
    s = path;
  const int slash = s.ReverseFind_PathSepar();
  if (slash >= 0)
  {
    const UString dir = s.Left((unsigned)slash + 1);
    HANDLE h = ::CreateFileW(dir, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h != INVALID_HANDLE_VALUE)
    {
      const DWORD len = ::GetFinalPathNameByHandleW(h, full, Z7_ARRAY_SIZE(full), FILE_NAME_NORMALIZED);
      ::CloseHandle(h);
      if (len != 0 && len < Z7_ARRAY_SIZE(full))
      {
        const UString leaf = s.Ptr() + slash + 1;
        s.SetFrom(full, (unsigned)len);
        if (!IS_PATH_SEPAR(s.Back())) s.Add_PathSepar();
        s += leaf;
      }
    }
  }
  ::CharUpperBuffW(s.Ptr_non_const(), s.Len());
  for (unsigned i = 0; i < s.Len(); i++)
  {
    wchar_t c = s[i];
    if (c == L'/') c = L'\\';
    if (c >= L'a' && c <= L'z') c = (wchar_t)(c - L'a' + L'A');
    s.ReplaceOneCharAtPos(i, c);
  }
  return s;
}

static UInt64 HashVaultPath(const UString &path)
{
  const UString s = GetCanonicalVaultPath(path);
  UInt64 h = 1469598103934665603ULL;
  for (unsigned i = 0; i < s.Len(); i++)
  {
    const UInt16 c = (UInt16)s[i];
    h ^= (Byte)c; h *= 1099511628211ULL;
    h ^= (Byte)(c >> 8); h *= 1099511628211ULL;
  }
  return h;
}

class CVaultSaveLock
{
  HANDLE _handle;
  bool _owned;
public:
  CVaultSaveLock(): _handle(NULL), _owned(false) {}
  ~CVaultSaveLock()
  {
    if (_owned) ::ReleaseMutex(_handle);
    if (_handle) ::CloseHandle(_handle);
  }
  bool Acquire(const UString &path)
  {
    if (!IsSafeVaultLeaf(path)) return false;
    UString name = L"Global\\7-Zip.PasswordVault.";
    name.Add_UInt64(HashVaultPath(path));
    _handle = ::CreateMutexW(NULL, FALSE, name);
    if (!_handle) return false;
    const DWORD waitResult = ::WaitForSingleObject(_handle, 30000);
    _owned = (waitResult == WAIT_OBJECT_0 || waitResult == WAIT_ABANDONED);
    if (!_owned && waitResult == WAIT_TIMEOUT) ::SetLastError(ERROR_TIMEOUT);
    return _owned && IsSafeVaultLeaf(path);
  }
};

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

// Empty coordination file, never vault data. Keep it in place: deleting a lock
// file while another process uses it would split the coordination identity.
// Readers allow other readers; restore requests a share-none handle. The OS
// releases handles on crashes. All opens happen under the canonical save mutex.
static HANDLE OpenVaultSession(const UString &path, bool exclusive)
{
  const UString lease = path + L".session.lock";
  if (!IsSafeVaultLeaf(lease)) return INVALID_HANDLE_VALUE;
  HANDLE h = ::CreateFileW(lease, GENERIC_READ, exclusive ? 0 : FILE_SHARE_READ,
      NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (h == INVALID_HANDLE_VALUE) return h;
  BY_HANDLE_FILE_INFORMATION info;
  if (!::GetFileInformationByHandle(h, &info) ||
      (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
      info.nNumberOfLinks != 1 || info.nFileSizeHigh != 0 || info.nFileSizeLow != 0)
  {
    ::CloseHandle(h);
    ::SetLastError(ERROR_ACCESS_DENIED);
    return INVALID_HANDLE_VALUE;
  }
  return h;
}

static bool WriteBuf(COutFile &f, const void *data, size_t size)
{
  return f.WriteFull(data, size);
}

class CVaultOutFile: public COutFile
{
public:
  bool CreateRestore(const UString &path)
  {
    return Create(path, GENERIC_WRITE | WRITE_DAC, FILE_SHARE_READ, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH);
  }
  bool CreateExclusive(const UString &path)
  {
    return Create(path, GENERIC_WRITE, FILE_SHARE_READ, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH);
  }
};

struct CTempVaultCleanup
{
  const UString &Path;
  bool Created;
  CTempVaultCleanup(const UString &path): Path(path), Created(false) {}
  ~CTempVaultCleanup() { if (Created) ::DeleteFileW(Path); }
};

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
  ::SecureZeroMemory(res.pbData, res.cbData);
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
  CVaultString Password;
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
    // A newly confirmed password is cached for the pending save even when the
    // user disabled remembering. Consume that one-shot value, then erase it.
    if (settings.RememberMasterPassword)
      g_MasterPasswordTick = ::GetTickCount();
    else
      ClearCachedMasterPassword();
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

static bool VaultFileExists(const UString &path)
{
  const DWORD attr = ::GetFileAttributesW(path);
  return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

UString CPasswordVault::GetDefaultPath()
{
  UString roaming = GetVaultFolderPath();
  if (roaming.IsEmpty()) return roaming;
  roaming.Add_PathSepar();
  roaming += kDefaultFileName;
  const UString folder = GetProgramFolderPath();
  if (!folder.IsEmpty())
  {
    const UString portable = folder + L"\\" + kDefaultFileName;
    if (VaultFileExists(portable) && !VaultFileExists(roaming))
      return portable;
  }
  return roaming;
}

/* The two default locations, filled in when the program folder is usable. */
static bool GetDefaultPair(UString &portable, UString &roaming)
{
  const UString programFolder = GetProgramFolderPath();
  if (programFolder.IsEmpty())
    return false;

  portable = programFolder;
  portable.Add_PathSepar();
  portable += kDefaultFileName;

  roaming = GetVaultFolderPath();
  if (roaming.IsEmpty()) return false;
  roaming.Add_PathSepar();
  roaming += kDefaultFileName;
  return true;
}

bool CPasswordVault::GetTwoDefaults(UString &portable, UString &roaming)
{
  NPasswordVault::CInfo settings;
  settings.Load();
  if (!settings.VaultPath.IsEmpty())
    return false;   /* the user already decided */

  if (!GetDefaultPair(portable, roaming))
    return false;
  return VaultFileExists(portable) && VaultFileExists(roaming);
}

void CPasswordVault::SetConfiguredPath(const UString &path)
{
  /* Only this one value: writing all nine (CInfo::Save) would roll back whatever the other
     process - 7zFM and 7zG share this key - changed while the user was answering. */
  NPasswordVault::CInfo::SaveVaultPath(us2fs(path));
}

UString CPasswordVault::AdoptPortableDefault()
{
  /* Compatibility entry point retained for callers from older builds. Sensitive
     data is no longer moved automatically; portable mode requires an explicit path. */
  return UString();
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

bool CPasswordVault::Load(HWND parent, UString &errorMessage, bool snapshotOnly)
{
  ReleaseSession();
  _snapshotOnly = snapshotOnly;
  errorMessage.Empty();
  ClearEntries();
  _baseline.Clear();
  _loadedImage.Free();
  _masterMode = false;
  /* Failed until a load really succeeded: every "return false" below - a bad version,
     a bad header, a decryption or parse failure - then keeps saving disabled without
     having to be listed here. */
  _readFailed = true;
  _haveLoadedMode = false;
  _loadedExisted = false;

  if (_path.IsEmpty())
  {
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, ERROR_PATH_NOT_FOUND);
    return false;
  }

  // Readers participate too: Windows read handles must not race a replacement,
  // and parsing plus the encrypted snapshot must refer to one file generation.
  CVaultSaveLock loadLock;
  if (!loadLock.Acquire(_path))
  {
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, ::GetLastError());
    return false;
  }

  if (!snapshotOnly)
  {
    EnsureFolderExists(_path);
    _session = OpenVaultSession(_path, false);
  }
  if (!snapshotOnly && _session == INVALID_HANDLE_VALUE)
  {
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, ::GetLastError());
    return false;
  }
  struct CFailedLoadSession
  {
    CPasswordVault &Vault;
    CFailedLoadSession(CPasswordVault &v): Vault(v) {}
    ~CFailedLoadSession() { if (Vault._readFailed) Vault.ReleaseSession(); }
  } failedSession(*this);

  CInFile f;
  if (!f.Open(_path))
  {
    /* "no file yet" and "cannot open the file" are very different: the first is an
       empty vault, the second (a lock, a permission problem, a read-only volume) used
       to look like an empty vault too - and then the next save wrote that empty list
       over the real file. */
    const DWORD sysError = ::GetLastError();
    if (sysError == ERROR_FILE_NOT_FOUND || sysError == ERROR_PATH_NOT_FOUND)
    {
      _readFailed = false; // really does not exist yet: an empty vault, not a failure
      return true;
    }
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, sysError);
    _readFailed = true;
    return false;
  }
  UInt64 fileLength = 0;
  if (!f.GetLength(fileLength) || fileLength > kMaxCipherSize + 65536)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
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
  if (!ReadBuf(f, &flags, 1) || flags > 1)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
    return false;
  }

  _masterMode = ((flags & 1) != 0);
  bool ok = _masterMode ? Load_Master(parent, f, errorMessage) : Load_DPAPI(f, version, errorMessage);
  Byte trailing;
  size_t processed = 0;
  UInt64 length = 0;
  if (ok)
  {
    ok = f.ReadFull(&trailing, 1, processed) && processed == 0 &&
        f.GetLength(length) && length <= kMaxCipherSize + 65536 && f.SeekToBegin();
    if (ok)
    {
      _loadedImage.Alloc((size_t)length);
      ok = ReadBuf(f, _loadedImage, (size_t)length);
    }
    if (!ok) SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
  }
  if (ok)
  {
    _readFailed = false;
    _haveLoadedMode = true;
    _loadedExisted = true;
    _baseline = _entries;
  }
  else
    ClearEntries();
  return ok;
}

bool CPasswordVault::EnsureAuthenticated(HWND parent, UString &errorMessage, bool *reloaded)
{
  if (reloaded) *reloaded = false;
  if (_readFailed)
  {
    if (reloaded) *reloaded = true;
    return Load(parent, errorMessage);
  }
  return !_readFailed;
}

static int FindExact(const CObjectVector<CPasswordVaultEntry> &entries, const CPasswordVaultEntry &e)
{
  FOR_VECTOR(i, entries)
    if (entries[i].Name == e.Name && entries[i].Password == e.Password) return (int)i;
  return -1;
}

bool CPasswordVault::Save(UString &errorMessage, HWND parent, int modeOverride)
{
  errorMessage.Empty();
  // Roll back even callers that forget to restore their UI snapshot.
  struct CRollback
  {
    CObjectVector<CPasswordVaultEntry> &entries;
    const CObjectVector<CPasswordVaultEntry> &baseline;
    bool committed;
    CRollback(CObjectVector<CPasswordVaultEntry> &e, const CObjectVector<CPasswordVaultEntry> &b):
        entries(e), baseline(b), committed(false) {}
    ~CRollback()
    {
      if (!committed)
      {
        CPasswordVault::ClearCachedMasterPassword();
        entries = baseline;
      }
    }
  } rollback(_entries, _baseline);
  if (!IsSafeVaultLeaf(_path) || !IsSafeVaultLeaf(_path + L".bak"))
  {
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, ::GetLastError());
    return false;
  }
  EnsureFolderExists(_path);
  CVaultSaveLock lock;
  if (_readFailed || _snapshotOnly || !lock.Acquire(_path))
  {
    SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
        L"无法打开密码库文件：\n{0}\n{1}", _path, _snapshotOnly ? ERROR_ACCESS_DENIED : (_readFailed ? 0 : ::GetLastError()));
    return false;
  }

  // Read the exact current bytes while holding the mutex. Mode/password changes
  // must not try to decrypt an unchanged old file using the new master password.
  CByteBuffer disk;
  bool exists = false;
  {
    CInFile f;
    if (f.Open(_path))
    {
      exists = true;
      UInt64 size = 0;
      if (!f.GetLength(size) || size > kMaxCipherSize + 65536) goto conflict;
      disk.Alloc((size_t)size);
      if (!ReadBuf(f, disk, disk.Size())) goto conflict;
    }
    else
    {
      const DWORD e = ::GetLastError();
      if (e != ERROR_FILE_NOT_FOUND && e != ERROR_PATH_NOT_FOUND)
      {
        SetPathError(errorMessage, IDT_PASSWORD_ERR_OPEN,
            L"无法打开密码库文件：\n{0}\n{1}", _path, e);
        return false;
      }
    }
  }
  {
    CPasswordVault candidate;
    candidate.SetPath(_path);
    if (exists == _loadedExisted && disk == _loadedImage)
    {
      candidate._entries = _entries;
      candidate._masterMode = _masterMode;
      candidate._haveLoadedMode = _haveLoadedMode;
      candidate._readFailed = false;
    }
    else
    {
      // A mode change needs a fresh confirmation if another writer intervened.
      // Deleting/recreating the vault must never resurrect an old snapshot.
      if (modeOverride >= 0 || (_loadedExisted && !exists)) goto conflict;
      if (!candidate.Load(parent, errorMessage)) return false;
      if (_haveLoadedMode && candidate._masterMode != _masterMode) goto conflict;
      CObjectVector<CPasswordVaultEntry> additions(_entries);
      FOR_VECTOR(i, _baseline)
      {
        const int unchanged = FindExact(additions, _baseline[i]);
        if (unchanged >= 0) additions.Delete((unsigned)unchanged);
        else
        {
          const int removed = FindExact(candidate._entries, _baseline[i]);
          if (removed < 0) goto conflict;
          candidate._entries.Delete((unsigned)removed);
        }
      }
      FOR_VECTOR(i, additions)
      {
        // Names are the UI's lookup keys. Never silently replace a concurrent
        // addition with the same name; unnamed records remain distinct.
        if (!additions[i].Name.IsEmpty() && candidate.FindByName(additions[i].Name) >= 0)
          goto conflict;
        candidate._entries.Add(additions[i]);
      }
    }
    if (!candidate.SaveFile(errorMessage, parent, modeOverride, disk, exists)) return false;
    _entries = candidate._entries;
    _baseline = candidate._entries;
    _loadedImage = candidate._loadedImage;
    _masterMode = candidate._masterMode;
    _haveLoadedMode = _loadedExisted = true;
    rollback.committed = true;
    return true;
  }
conflict:
  SetPathError(errorMessage, IDT_PASSWORD_ERR_CHANGED,
      L"密码库已被另一个窗口修改，请重新打开：\n{0}", _path, 0);
  return false;
}

bool CPasswordVault::SaveFile(UString &errorMessage, HWND parent, int modeOverride,
    const CByteBuffer &previousImage, bool existed)
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
  bool savedUseMaster = false;

  /* Write to a temporary file first, then replace the real file atomically.
     Otherwise a crash / power loss in the middle of a write would destroy
     the whole vault (all saved passwords). */
  UString tmpPath = _path + L".tmp";
  {
    /* 7zFM and 7zG can save at the same time: without the process id they would write
       the same temporary file and replace the vault with a half written one. */
    static LONG tempSerial = 0;
    UString unique;
    unique.Add_UInt32((UInt32)::GetCurrentProcessId());
    unique += L".";
    unique.Add_UInt32((UInt32)::GetTickCount());
    unique += L".";
    unique.Add_UInt32((UInt32)::InterlockedIncrement(&tempSerial));
    tmpPath += L".";
    tmpPath += unique;
  }

  CTempVaultCleanup cleanup(tmpPath);
  {
    CVaultOutFile f;
    if (!f.CreateExclusive(tmpPath))
    {
      const DWORD sysError = ::GetLastError();
      SetPathError(errorMessage, IDT_PASSWORD_ERR_CREATE, L"无法创建密码库文件：\n{0}\n{1}",
          _path, sysError);
      return false;
    }
    cleanup.Created = true;

    bool ok = WriteBuf(f, kMagic, 4) && WriteBuf(f, &kVersion, 1);
    if (!ok) SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");

    if (ok)
    {
      NPasswordVault::CInfo settings;
      settings.Load();
      /* The mode belongs to the file: when this object read one, that file's mode is
         kept. Only a new vault takes the setting as its default, and an explicit change
         from the settings page overrides both. */
      bool useMaster = _haveLoadedMode ? _masterMode : (settings.UseMasterPassword != 0);
      if (modeOverride >= 0)
        useMaster = (modeOverride != 0);
      savedUseMaster = useMaster;
      const Byte flags = useMaster ? 1 : 0;
      ok = WriteBuf(f, &flags, 1);
      if (!ok) SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
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

    if (ok && !::FlushFileBuffers(f.GetHandle()))
    {
      ok = false;
      SetPathError(errorMessage, IDT_PASSWORD_ERR_WRITE,
          L"无法写入密码库文件：\n{0}\n{1}", _path, ::GetLastError());
    }
    f.Close();

    if (!ok)
    {
      ::DeleteFileW(tmpPath);
      return false;
    }
  }

  // Capture the exact encrypted output before the commit, while failures can
  // still leave the original file untouched.
  {
    CInFile check;
    UInt64 size = 0;
    if (!check.Open(tmpPath) || !check.GetLength(size) || size > kMaxCipherSize + 65536)
    {
      check.Close();
      ::DeleteFileW(tmpPath);
      SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
      return false;
    }
    _loadedImage.Alloc((size_t)size);
    if (!ReadBuf(check, _loadedImage, _loadedImage.Size()))
    {
      check.Close();
      ::DeleteFileW(tmpPath);
      SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
      return false;
    }
  }
  // Preserve the exact encrypted generation read under the save mutex. No
  // decryption/re-encryption: after a master change the backup needs the OLD key.
  // Publish a fully flushed backup before replacing the primary vault. If backup
  // creation fails, abort the save and leave the primary untouched.
  if (existed)
  {
    const UString backupPath = _path + L".bak";
    if (!IsSafeVaultLeaf(_path) || !IsSafeVaultLeaf(backupPath))
    {
      SetPathError(errorMessage, IDT_PASSWORD_ERR_REPLACE,
          L"无法替换密码库文件：\n{0}\n{1}", backupPath, ::GetLastError());
      return false;
    }
    const UString backupTemp = tmpPath + L".bak";
    CTempVaultCleanup backupCleanup(backupTemp);
    {
      CVaultOutFile backup;
      if (!backup.CreateExclusive(backupTemp))
      {
        SetPathError(errorMessage, IDT_PASSWORD_ERR_CREATE,
            L"无法创建密码库文件：\n{0}\n{1}", backupPath, ::GetLastError());
        return false;
      }
      backupCleanup.Created = true;
      if (!WriteBuf(backup, previousImage, previousImage.Size()) ||
          !::FlushFileBuffers(backup.GetHandle()) || !backup.Close())
      {
        SetPathError(errorMessage, IDT_PASSWORD_ERR_WRITE,
            L"无法写入密码库文件：\n{0}\n{1}", backupPath, ::GetLastError());
        return false;
      }
    }
    if (!MoveVaultFileWithRetry(backupTemp, backupPath))
    {
      SetPathError(errorMessage, IDT_PASSWORD_ERR_REPLACE,
          L"无法替换密码库文件：\n{0}\n{1}", backupPath, ::GetLastError());
      return false;
    }
  }
  if (!MoveVaultFileWithRetry(tmpPath, _path))
  {
    /* The reason is captured before anything else runs: DeleteFileW below would
       overwrite it. */
    const DWORD sysError = ::GetLastError();
    SetPathError(errorMessage, IDT_PASSWORD_ERR_REPLACE, L"无法替换密码库文件：\n{0}\n{1}",
        _path, sysError);
    ::DeleteFileW(tmpPath);
    return false;
  }

  /* Commit both the file snapshot and the mode actually written. */
  _masterMode = savedUseMaster;
  _haveLoadedMode = true;
  _loadedExisted = true;
  _readFailed = false;


  return true;
}

bool CPasswordVault::SerializeEntries(CByteBuffer &out, UString &errorMessage)
{
  size_t total = 4;
  FOR_VECTOR(i, _entries)
  {
    const CPasswordVaultEntry &e = _entries[i];
    const size_t nameBytes = (size_t)e.Name.Len() * sizeof(wchar_t);
    const size_t passBytes = (size_t)e.Password.Len() * sizeof(wchar_t);
    if (nameBytes > kMaxNameBytes || passBytes > kMaxBlobSize ||
        total > kMaxCipherSize - 8 || nameBytes > kMaxCipherSize - total - 8 ||
        passBytes > kMaxCipherSize - total - 8 - nameBytes)
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据过大");
      return false;
    }
    total += 8 + nameBytes + passBytes;
  }
  if (total > kMaxCipherSize || _entries.Size() > kMaxEntries)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据过大");
    return false;
  }

  out.ChangeSize_KeepData(total, 0);
  Byte *dest = (Byte *)(void *)out;
  size_t pos = 0;
  const UInt32 count = (UInt32)_entries.Size();
  memcpy(dest + pos, &count, 4); pos += 4;
  FOR_VECTOR(i, _entries)
  {
    const CPasswordVaultEntry &e = _entries[i];
    const UInt32 nameBytes = (UInt32)((size_t)e.Name.Len() * sizeof(wchar_t));
    memcpy(dest + pos, &nameBytes, 4); pos += 4;
    if (nameBytes) { memcpy(dest + pos, (const wchar_t *)e.Name, nameBytes); pos += nameBytes; }
    const UInt32 passBytes = (UInt32)((size_t)e.Password.Len() * sizeof(wchar_t));
    memcpy(dest + pos, &passBytes, 4); pos += 4;
    if (passBytes) { memcpy(dest + pos, (const wchar_t *)e.Password, passBytes); pos += passBytes; }
  }
  return true;
}

bool CPasswordVault::ParseEntries(const Byte *data, size_t size, UString &errorMessage)
{
  size_t pos = 0;
  UInt32 count = 0;
  if (!ReadUInt32Mem(data, size, pos, count) || count > kMaxEntries)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
    return false;
  }

  for (UInt32 i = 0; i < count; i++)
  {
    CPasswordVaultEntry entry;
    UInt32 nameBytes = 0;
    if (!ReadUInt32Mem(data, size, pos, nameBytes) || (nameBytes & 1) != 0 ||
        nameBytes > kMaxNameBytes || nameBytes > size - pos)
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
      return false;
    }
    {
      const unsigned charCount = nameBytes / 2;
      wchar_t *p = entry.Name.GetBuf(charCount);
      if (nameBytes) memcpy(p, data + pos, nameBytes);
      p[charCount] = 0;
      entry.Name.ReleaseBuf_SetLen(charCount);
    }
    pos += nameBytes;

    UInt32 passBytes = 0;
    if (!ReadUInt32Mem(data, size, pos, passBytes) || (passBytes & 1) != 0 ||
        passBytes > kMaxBlobSize || passBytes > size - pos)
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
      return false;
    }
    {
      const unsigned charCount = passBytes / 2;
      wchar_t *p = entry.Password.GetBuf(charCount);
      if (passBytes) memcpy(p, data + pos, passBytes);
      p[charCount] = 0;
      entry.Password.ReleaseBuf_SetLen(charCount);
    }
    pos += passBytes;
    _entries.Add(entry);
  }

  if (pos != size)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_DATA, L"密码库数据已损坏");
    return false;
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

  CByteBuffer_Wipe plain(0);
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

  CByteBuffer_Wipe buf(bytes);
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
  if (version >= 4)
  {
    UInt32 blobSize = 0;
    if (!ReadUInt32(f, blobSize) || blobSize == 0 || blobSize > kMaxCipherSize + 65536)
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
      return false;
    }
    CByteBuffer blob(blobSize);
    if (!ReadBuf(f, blob, blobSize))
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
      return false;
    }
    CByteBuffer_Wipe plain(0);
    if (!DpapiUnprotect((const Byte *)blob, blobSize, plain))
    {
      SetError(errorMessage, IDT_PASSWORD_ERR_DECRYPT,
          L"解密失败（文件可能被篡改，或不是同一个 Windows 账户或电脑）");
      return false;
    }
    const bool ok = ParseEntries((const Byte *)plain, plain.Size(), errorMessage);
    plain.Wipe();
    return ok;
  }

  UInt32 count = 0;
  if (!ReadUInt32(f, count) || count > kMaxEntries)
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_FILE, L"密码库文件已损坏或无效");
    return false;
  }
  for (UInt32 i = 0; i < count; i++)
  {
    CPasswordVaultEntry entry;
    const bool nameOk = (version >= 3)
        ? Read_DPAPI_String(f, entry.Name, errorMessage)
        : Read_PlainString(f, entry.Name, errorMessage);
    if (!nameOk || !Read_DPAPI_String(f, entry.Password, errorMessage))
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

  CVaultString master;
  if (!GetMasterPassword(parent, master, errorMessage))
    return false;

  CByteBuffer_Wipe key(kKeySize);
  if (!DeriveKey(master, salt, kSaltSize, iterations, key))
  {
    SecureWipeString(master);
    SetError(errorMessage, IDT_PASSWORD_ERR_KDF, L"密钥派生失败");
    return false;
  }

  CByteBuffer_Wipe plain(cipherLen);
  const bool decOk = AesGcm(false, key, iv, kIvSize,
      (const Byte *)cipher, cipherLen, (Byte *)plain, tag, kTagSize);
  key.Wipe();
  SecureWipeString(master);
  if (!decOk)
  {
    ClearCachedMasterPassword();
    SetError(errorMessage, IDT_PASSWORD_ERR_MASTER, L"主密码错误，或密码库文件已损坏");
    return false;
  }

  const bool parsed = ParseEntries((const Byte *)plain, cipherLen, errorMessage);
  plain.Wipe();
  return parsed;
}

bool CPasswordVault::Save_DPAPI(COutFile &f, UString &errorMessage)
{
  CByteBuffer_Wipe plain(0);
  if (!SerializeEntries(plain, errorMessage))
    return false;
  CByteBuffer blob;
  if (!DpapiProtect((const Byte *)plain, plain.Size(), blob))
  {
    plain.Wipe();
    SetError(errorMessage, IDT_PASSWORD_ERR_ENCRYPT, L"加密失败");
    return false;
  }
  plain.Wipe();
  const UInt32 blobSize = (UInt32)blob.Size();
  if (!WriteUInt32(f, blobSize) || !WriteBuf(f, (const Byte *)blob, blobSize))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
    return false;
  }
  return true;
}

bool CPasswordVault::Save_Master(COutFile &f, UString &errorMessage, HWND parent)
{
  CVaultString master;
  if (!GetMasterPassword(parent, master, errorMessage))
    return false;

  Byte salt[kSaltSize];
  Byte iv[kIvSize];
  if (!GenRandom(salt, kSaltSize) || !GenRandom(iv, kIvSize))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_RANDOM, L"随机数生成失败");
    return false;
  }

  CByteBuffer_Wipe key(kKeySize);
  if (!DeriveKey(master, salt, kSaltSize, kPbkdf2Iterations, key))
  {
    SecureWipeString(master);
    SetError(errorMessage, IDT_PASSWORD_ERR_KDF, L"密钥派生失败");
    return false;
  }
  SecureWipeString(master);

  CByteBuffer_Wipe plain(0);
  if (!SerializeEntries(plain, errorMessage))
  {
    key.Wipe();
    return false;
  }
  const UInt32 plainSize = (UInt32)plain.Size();
  CByteBuffer cipher(plainSize);
  Byte tag[kTagSize];
  const bool encOk = AesGcm(true, key, iv, kIvSize,
      (const Byte *)plain, plainSize, (Byte *)cipher, tag, kTagSize);
  key.Wipe();
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
      !WriteUInt32(f, plainSize) ||
      !WriteBuf(f, (const Byte *)cipher, plainSize))
  {
    SetError(errorMessage, IDT_PASSWORD_ERR_WRITE, L"无法写入密码库文件");
    return false;
  }

  plain.Wipe();
  return true;
}

namespace
{
struct CRestoreHandle
{
  HANDLE Value;
  CRestoreHandle(HANDLE h = INVALID_HANDLE_VALUE): Value(h) {}
  ~CRestoreHandle()
  {
    const DWORD error = ::GetLastError();
    if (Value != INVALID_HANDLE_VALUE) ::CloseHandle(Value);
    ::SetLastError(error);
  }
};
struct CRestoreCacheClear
{
  ~CRestoreCacheClear() { CPasswordVault::ClearCachedMasterPassword(); }
};
struct CRestoreSecurity
{
  PSECURITY_DESCRIPTOR Value;
  CRestoreSecurity(): Value(NULL) {}
  ~CRestoreSecurity() { if (Value) ::LocalFree(Value); }
};

bool ReadRestoreImage(const UString &path, CByteBuffer &bytes, bool &exists,
    FILETIME *time = NULL)
{
  bytes.Free();
  exists = false;
  if (!IsSafeVaultLeaf(path)) return false;
  CRestoreHandle f(::CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL));
  if (f.Value == INVALID_HANDLE_VALUE)
    return ::GetLastError() == ERROR_FILE_NOT_FOUND;
  BY_HANDLE_FILE_INFORMATION info;
  if (!::GetFileInformationByHandle(f.Value, &info)) return false;
  if ((info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
      info.nNumberOfLinks != 1 || info.nFileSizeHigh || info.nFileSizeLow > kMaxCipherSize + 65536)
  {
    ::SetLastError(ERROR_INVALID_DATA);
    return false;
  }
  exists = true;
  if (time) *time = info.ftLastWriteTime;
  bytes.Alloc(info.nFileSizeLow);
  DWORD read = 0;
  if (!::ReadFile(f.Value, bytes, info.nFileSizeLow, &read, NULL)) return false;
  if (read != info.nFileSizeLow) { ::SetLastError(ERROR_HANDLE_EOF); return false; }
  return true;
}

bool WriteRestoreImage(const UString &path, const CByteBuffer &bytes,
    PSECURITY_DESCRIPTOR security, bool &created)
{
  CVaultOutFile f;
  if (!f.CreateRestore(path)) return false;
  created = true;
  // Apply the old file's DACL before writing any ciphertext. Mark it protected
  // so the directory cannot add broader inherited permissions to this copy.
  bool ok = !security || ::SetKernelObjectSecurity(f.GetHandle(),
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, security) != 0;
  if (ok) ok = WriteBuf(f, bytes, bytes.Size()) && ::FlushFileBuffers(f.GetHandle());
  DWORD error = ok ? ERROR_SUCCESS : ::GetLastError();
  if (!f.Close() && ok) { ok = false; error = ::GetLastError(); }
  if (!ok) { ::SetLastError(error); return false; }
  CByteBuffer check;
  bool exists = false;
  if (!ReadRestoreImage(path, check, exists)) return false;
  if (!exists || check != bytes) { ::SetLastError(ERROR_CRC); return false; }
  return true;
}
}

bool CPasswordVaultRestore::Fail(const wchar_t *stage, DWORD code, UString &error)
{
  _ready = false;
  Stage = stage;
  SystemError = code;
  SetPathError(error, IDT_PASSWORD_RESTORE_FAILED,
      L"恢复未提交，当前密码库和备份未改变。\n{0}\n{1}", _path, code);
  error += L"\n[";
  error += stage;
  error += L", Win32=";
  error.Add_UInt32(code);
  error += L"]";
  CPasswordVault::ClearCachedMasterPassword();
  ::SetLastError(code);
  return false;
}

bool CPasswordVaultRestore::Prepare(const UString &path, HWND parent, UString &error)
{
  CRestoreCacheClear clear;
  CPasswordVault::ClearCachedMasterPassword();
  _ready = false;
  Committed = false;
  SafetyCopyPath.Empty();
  SystemError = 0;
  error.Empty();
  _backup.SetPath(UString());
  _path = PasswordVault_NormalizePath(path);
  _canonical = GetCanonicalVaultPath(_path);
  Stage = L"snapshot";
  CByteBuffer source;
  bool exists = false;
  {
    CVaultSaveLock lock;
    if (!lock.Acquire(_path) || !ReadRestoreImage(_path, _original, _existed) ||
        !ReadRestoreImage(_path + L".bak", source, exists, &BackupTime))
      return Fail(L"snapshot", ::GetLastError(), error);
  }
  if (!exists) return Fail(L"backup-missing", ERROR_FILE_NOT_FOUND, error);
  if (source.Size() < 6 || memcmp(source, kMagic, 4) != 0 || source[4] != 4)
    return Fail(L"backup-format-v4-required", ERROR_INVALID_DATA, error);
  Stage = L"authenticate-backup";
  _backup.SetPath(_path + L".bak");
  // No main-vault mutex is held while the user supplies the backup's password.
  if (!_backup.Load(parent, error, true)) return false;
  if (!_backup._loadedExisted || _backup._loadedImage != source)
    return Fail(L"backup-changed", ERROR_REVISION_MISMATCH, error);
  _ready = true;
  Stage = L"ready";
  return true;
}

bool CPasswordVaultRestore::Commit(UString &error)
{
  CRestoreCacheClear clear;
  error.Empty();
  if (!_ready || Committed) return Fail(L"not-prepared", ERROR_INVALID_STATE, error);
  _ready = false; // Single-use, even if this attempt fails.
  CVaultSaveLock lock;
  if (!lock.Acquire(_path)) return Fail(L"save-lock", ::GetLastError(), error);
  if (GetCanonicalVaultPath(_path) != _canonical)
    return Fail(L"parent-changed", ERROR_REVISION_MISMATCH, error);
  const int separator = _canonical.ReverseFind_PathSepar();
  const UString folder = _canonical.Left((unsigned)separator + 1);
  CRestoreHandle parent(::CreateFileW(folder, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL));
  if (parent.Value == INVALID_HANDLE_VALUE || GetCanonicalVaultPath(_path) != _canonical)
    return Fail(L"pin-parent", ERROR_ACCESS_DENIED, error);
  CRestoreHandle session(OpenVaultSession(_path, true));
  if (session.Value == INVALID_HANDLE_VALUE)
    return Fail(L"vault-in-use-close-password-windows", ::GetLastError(), error);
  CByteBuffer current, backup;
  bool exists = false, backupExists = false;
  if (!ReadRestoreImage(_path, current, exists) ||
      !ReadRestoreImage(_path + L".bak", backup, backupExists))
    return Fail(L"recheck", ::GetLastError(), error);
  if (exists != _existed || current != _original || !backupExists || backup != _backup._loadedImage)
    return Fail(L"files-changed", ERROR_REVISION_MISMATCH, error);
  if (exists && current == backup) { Stage = L"already-current"; return true; }

  CRestoreSecurity security;
  if (exists)
  {
    const DWORD e = ::GetNamedSecurityInfoW((LPWSTR)(LPCWSTR)_path, SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION, NULL, NULL, NULL, NULL, &security.Value);
    if (e != ERROR_SUCCESS) return Fail(L"read-current-acl", e, error);
  }
  Byte nonce[16];
  if (!GenRandom(nonce, sizeof(nonce))) return Fail(L"random-name", ERROR_GEN_FAILURE, error);
  UString suffix;
  SYSTEMTIME now;
  ::GetSystemTime(&now);
  suffix.Add_UInt32(now.wYear); suffix += L"-";
  suffix.Add_UInt32(now.wMonth); suffix += L"-";
  suffix.Add_UInt32(now.wDay); suffix += L"-";
  const wchar_t hex[] = L"0123456789abcdef";
  for (unsigned i = 0; i < sizeof(nonce); ++i)
  { suffix += hex[nonce[i] >> 4]; suffix += hex[nonce[i] & 15]; }
  if (exists)
  {
    SafetyCopyPath = _path + L".pre-restore-" + suffix;
    CTempVaultCleanup partial(SafetyCopyPath);
    if (!WriteRestoreImage(SafetyCopyPath, current, security.Value, partial.Created))
      return Fail(L"preserve-current", ::GetLastError(), error);
    partial.Created = false; // Keep a complete, verified safety copy even on later failure.
  }
  const UString temporary = _path + L".restore-tmp-" + suffix;
  CTempVaultCleanup cleanup(temporary);
  if (!WriteRestoreImage(temporary, backup, security.Value, cleanup.Created))
    return Fail(L"write-restored-image", ::GetLastError(), error);
  // Revalidate leaf safety immediately before publication. Never follow links.
  if (!IsSafeVaultLeaf(_path) || !IsSafeVaultLeaf(_path + L".bak"))
    return Fail(L"unsafe-target", ::GetLastError(), error);
  if (GetCanonicalVaultPath(_path) != _canonical ||
      !ReadRestoreImage(_path, current, exists) || !ReadRestoreImage(_path + L".bak", backup, backupExists) ||
      exists != _existed || current != _original || !backupExists || backup != _backup._loadedImage)
    return Fail(L"changed-before-replace", ERROR_REVISION_MISMATCH, error);
  Stage = L"replace-primary";
  const bool moved = exists ? MoveVaultFileWithRetry(temporary, _path) :
      (::MoveFileExW(temporary, _path, MOVEFILE_WRITE_THROUGH) != 0);
  if (!moved) return Fail(L"replace-primary", ::GetLastError(), error);
  // No fallible parsing, credential prompt or allocation after the commit point.
  Committed = true;
  cleanup.Created = false;
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

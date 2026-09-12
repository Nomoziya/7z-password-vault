// PasswordVault.cpp

#include "StdAfx.h"

#include <wincrypt.h>
#include <dpapi.h>
#include <bcrypt.h>

#include "../../../Windows/FileIO.h"

#include "../Common/ZipRegistry.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "PasswordVault.h"

using namespace NWindows;
using namespace NFile;
using namespace NIO;

static const char kMagic[4] = { '7', 'Z', 'P', 'V' };
static const Byte kVersion = 2;

static const unsigned kSaltSize = 16;
static const unsigned kIvSize = 12;
static const unsigned kTagSize = 16;
static const unsigned kKeySize = 32;
static const UInt32 kPbkdf2Iterations = 200000;

// ---------------------------------------------------------------------------
// master password session cache

static UString g_MasterPassword;
static bool g_HaveMasterPassword = false;

void CPasswordVault::SetCachedMasterPassword(const UString &password)
{
  g_MasterPassword = password;
  g_HaveMasterPassword = true;
}

void CPasswordVault::ClearCachedMasterPassword()
{
  g_MasterPassword.Empty();
  g_HaveMasterPassword = false;
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

static void EnsureFolderExists(const UString &filePath)
{
  const int pos = filePath.ReverseFind_PathSepar();
  if (pos > 0)
  {
    const UString dir = filePath.Left((unsigned)pos);
    ::CreateDirectoryW(dir, NULL);
  }
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
    errorMessage = L"Master password was not entered";
    return false;
  }
  password = dialog.Password;
  return true;
}

bool CPasswordVault::GetMasterPassword(HWND parent, UString &password, UString &errorMessage)
{
  if (g_HaveMasterPassword)
  {
    password = g_MasterPassword;
    return true;
  }

  if (!PromptForMasterPassword(parent, password, errorMessage))
    return false;

  NPasswordVault::CInfo settings;
  settings.Load();
  if (settings.RememberMasterPassword)
    SetCachedMasterPassword(password);

  return true;
}

// ---------------------------------------------------------------------------
// path

UString CPasswordVault::GetDefaultPath()
{
  UString path = GetVaultFolderPath();
  path += L"\\7zPasswordVault.dat";
  return path;
}

UString CPasswordVault::GetConfiguredPath()
{
  NPasswordVault::CInfo settings;
  settings.Load();
  if (!settings.VaultPath.IsEmpty())
    return settings.VaultPath;
  return CPasswordVault::GetDefaultPath();
}

// ---------------------------------------------------------------------------
// load / save

bool CPasswordVault::Load(HWND parent, UString &errorMessage)
{
  _entries.Clear();
  _masterMode = false;

  CInFile f;
  if (!f.Open(_path))
    return true; // no file -> empty vault

  char magic[4];
  if (!ReadBuf(f, magic, 4) || memcmp(magic, kMagic, 4) != 0)
  {
    errorMessage = L"Invalid vault file header";
    return false;
  }

  Byte version = 0;
  if (!ReadBuf(f, &version, 1) || version != kVersion)
  {
    errorMessage = L"Unsupported vault file version";
    return false;
  }

  Byte flags = 0;
  if (!ReadBuf(f, &flags, 1))
  {
    errorMessage = L"Invalid vault file";
    return false;
  }

  _masterMode = ((flags & 1) != 0);
  return _masterMode ? Load_Master(parent, f, errorMessage) : Load_DPAPI(f, errorMessage);
}

bool CPasswordVault::Save(UString &errorMessage)
{
  EnsureFolderExists(_path);

  COutFile f;
  if (!f.Create_ALWAYS(_path))
  {
    errorMessage = L"Cannot create vault file";
    return false;
  }

  if (!WriteBuf(f, kMagic, 4) || !WriteBuf(f, &kVersion, 1))
  {
    errorMessage = L"Cannot write vault file";
    return false;
  }

  NPasswordVault::CInfo settings;
  settings.Load();
  const bool useMaster = settings.UseMasterPassword;

  const Byte flags = useMaster ? 1 : 0;
  if (!WriteBuf(f, &flags, 1))
  {
    errorMessage = L"Cannot write vault file";
    return false;
  }

  return useMaster ? Save_Master(f, errorMessage) : Save_DPAPI(f, errorMessage);
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
    errorMessage = L"Invalid vault data";
    return false;
  }

  for (UInt32 i = 0; i < count; i++)
  {
    UInt32 nameBytes = 0;
    if (!ReadUInt32Mem(data, size, pos, nameBytes) || (nameBytes & 1) != 0 || pos + nameBytes > size)
    {
      errorMessage = L"Invalid vault data";
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
      errorMessage = L"Invalid vault data";
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

bool CPasswordVault::Load_DPAPI(CInFile &f, UString &errorMessage)
{
  UInt32 count = 0;
  if (!ReadUInt32(f, count))
  {
    errorMessage = L"Invalid vault file";
    return false;
  }

  for (UInt32 i = 0; i < count; i++)
  {
    CPasswordVaultEntry entry;

    UInt32 nameBytes = 0;
    if (!ReadUInt32(f, nameBytes) || (nameBytes & 1) != 0)
    {
      errorMessage = L"Invalid vault entry";
      return false;
    }
    {
      CByteBuffer nameBuf(nameBytes);
      if (nameBytes != 0 && !ReadBuf(f, nameBuf, nameBytes))
      {
        errorMessage = L"Invalid vault entry";
        return false;
      }
      const unsigned charCount = nameBytes / 2;
      wchar_t *p = entry.Name.GetBuf(charCount);
      if (nameBytes != 0)
        memcpy(p, (const Byte *)nameBuf, nameBytes);
      p[charCount] = 0;
      entry.Name.ReleaseBuf_SetLen(charCount);
    }

    UInt32 blobSize = 0;
    if (!ReadUInt32(f, blobSize))
    {
      errorMessage = L"Invalid vault entry";
      return false;
    }
    {
      CByteBuffer blob(blobSize);
      if (blobSize != 0 && !ReadBuf(f, blob, blobSize))
      {
        errorMessage = L"Invalid vault entry";
        return false;
      }

      CByteBuffer plain;
      if (!DpapiUnprotect((const Byte *)blob, blobSize, plain))
      {
        errorMessage = L"Decryption failed (different user or machine)";
        return false;
      }
      if ((plain.Size() & 1) != 0)
      {
        errorMessage = L"Invalid password data";
        return false;
      }
      const unsigned charCount = (unsigned)(plain.Size() / 2);
      wchar_t *p = entry.Password.GetBuf(charCount);
      memcpy(p, (const Byte *)plain, plain.Size());
      p[charCount] = 0;
      entry.Password.ReleaseBuf_SetLen(charCount);
      plain.Wipe();
    }

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
      !ReadBuf(f, iv, kIvSize) || !ReadBuf(f, tag, kTagSize) || !ReadUInt32(f, cipherLen))
  {
    errorMessage = L"Invalid vault file";
    return false;
  }

  CByteBuffer cipher(cipherLen);
  if (cipherLen != 0 && !ReadBuf(f, cipher, cipherLen))
  {
    errorMessage = L"Invalid vault file";
    return false;
  }

  UString master;
  if (!GetMasterPassword(parent, master, errorMessage))
    return false;

  Byte key[kKeySize];
  if (!DeriveKey(master, salt, kSaltSize, iterations, key))
  {
    errorMessage = L"Key derivation failed";
    return false;
  }

  CByteBuffer plain(cipherLen);
  if (!AesGcm(false, key, iv, kIvSize,
      (const Byte *)cipher, cipherLen, (Byte *)plain, tag, kTagSize))
  {
    errorMessage = L"Wrong master password or corrupted vault file";
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
    errorMessage = L"Cannot write vault file";
    return false;
  }

  FOR_VECTOR(i, _entries)
  {
    const CPasswordVaultEntry &entry = _entries[i];

    const UInt32 nameBytes = (UInt32)(entry.Name.Len() * 2);
    if (!WriteUInt32(f, nameBytes))
    {
      errorMessage = L"Cannot write vault file";
      return false;
    }
    if (nameBytes != 0 && !WriteBuf(f, (const void *)(const wchar_t *)entry.Name, nameBytes))
    {
      errorMessage = L"Cannot write vault file";
      return false;
    }

    CByteBuffer blob;
    if (!DpapiProtect((const void *)(const wchar_t *)entry.Password,
        (size_t)entry.Password.Len() * 2, blob))
    {
      errorMessage = L"Encryption failed";
      return false;
    }
    const UInt32 blobSize = (UInt32)blob.Size();
    if (!WriteUInt32(f, blobSize) || (blobSize != 0 && !WriteBuf(f, (const Byte *)blob, blobSize)))
    {
      errorMessage = L"Cannot write vault file";
      return false;
    }
  }

  return true;
}

bool CPasswordVault::Save_Master(COutFile &f, UString &errorMessage)
{
  UString master;
  if (!GetMasterPassword(NULL, master, errorMessage))
    return false;

  Byte salt[kSaltSize];
  Byte iv[kIvSize];
  if (!GenRandom(salt, kSaltSize) || !GenRandom(iv, kIvSize))
  {
    errorMessage = L"Random generation failed";
    return false;
  }

  Byte key[kKeySize];
  if (!DeriveKey(master, salt, kSaltSize, kPbkdf2Iterations, key))
  {
    errorMessage = L"Key derivation failed";
    return false;
  }

  CByteBuffer plain;
  SerializeEntries(plain);

  CByteBuffer cipher(plain.Size());
  Byte tag[kTagSize];
  if (!AesGcm(true, key, iv, kIvSize,
      (const Byte *)plain, (unsigned)plain.Size(), (Byte *)cipher, tag, kTagSize))
  {
    errorMessage = L"Encryption failed";
    return false;
  }

  if (!WriteBuf(f, salt, kSaltSize) ||
      !WriteUInt32(f, kPbkdf2Iterations) ||
      !WriteBuf(f, iv, kIvSize) ||
      !WriteBuf(f, tag, kTagSize) ||
      !WriteUInt32(f, (UInt32)plain.Size()) ||
      !WriteBuf(f, (const Byte *)cipher, plain.Size()))
  {
    errorMessage = L"Cannot write vault file";
    return false;
  }

  plain.Wipe();
  return true;
}

int CPasswordVault::FindByName(const UString &name) const
{
  FOR_VECTOR(i, _entries)
    if (_entries[i].Name == name)
      return (int)i;
  return -1;
}

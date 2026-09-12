// PasswordVault.cpp

#include "StdAfx.h"

#include <wincrypt.h>
#include <dpapi.h>

#include "../../../Windows/FileIO.h"

#include "PasswordVault.h"

using namespace NWindows;
using namespace NFile;
using namespace NIO;

static const char kMagic[4] = { '7', 'Z', 'P', 'V' };
static const Byte kVersion = 1;

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

UString CPasswordVault::GetDefaultPath()
{
  UString path = GetVaultFolderPath();
  path += L"\\7zPasswordVault.dat";
  return path;
}

bool CPasswordVault::Load(UString &errorMessage)
{
  _entries.Clear();

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
      UString name;
      wchar_t *p = name.GetBuf(charCount);
      memcpy(p, (const Byte *)nameBuf, nameBytes);
      p[charCount] = 0;
      name.ReleaseBuf_SetLen(charCount);
      entry.Name = name;
    }

    UInt32 blobSize = 0;
    if (!ReadUInt32(f, blobSize))
    {
      errorMessage = L"Invalid vault entry";
      return false;
    }

    entry.EncryptedPassword.Alloc(blobSize);
    if (blobSize != 0 && !ReadBuf(f, entry.EncryptedPassword, blobSize))
    {
      errorMessage = L"Invalid vault entry";
      return false;
    }

    _entries.Add(entry);
  }

  return true;
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

    const UInt32 blobSize = (UInt32)entry.EncryptedPassword.Size();
    if (!WriteUInt32(f, blobSize))
    {
      errorMessage = L"Cannot write vault file";
      return false;
    }
    if (blobSize != 0 && !WriteBuf(f, (const void *)(const Byte *)entry.EncryptedPassword, blobSize))
    {
      errorMessage = L"Cannot write vault file";
      return false;
    }
  }

  return true;
}

int CPasswordVault::FindByName(const UString &name) const
{
  FOR_VECTOR(i, _entries)
    if (_entries[i].Name == name)
      return (int)i;
  return -1;
}

bool CPasswordVault::EncryptPassword(const UString &password, CByteBuffer &blob, UString &errorMessage)
{
  CByteBuffer plain;
  plain.CopyFrom((const Byte *)password.Ptr(), (size_t)password.Len() * sizeof(wchar_t));

  DATA_BLOB in, out;
  in.pbData = (BYTE *)(Byte *)plain;
  in.cbData = (DWORD)plain.Size();
  out.pbData = NULL;
  out.cbData = 0;

  if (!CryptProtectData(&in, L"7-Zip Password Vault", NULL, NULL, NULL, 0, &out))
  {
    errorMessage = L"CryptProtectData failed";
    return false;
  }

  blob.CopyFrom((const Byte *)out.pbData, (size_t)out.cbData);
  LocalFree(out.pbData);
  return true;
}

bool CPasswordVault::DecryptPassword(const CByteBuffer &blob, UString &password, UString &errorMessage)
{
  CByteBuffer cipher = blob; // non-const copy for DATA_BLOB

  DATA_BLOB in, out;
  in.pbData = (BYTE *)(Byte *)cipher;
  in.cbData = (DWORD)cipher.Size();
  out.pbData = NULL;
  out.cbData = 0;

  if (!CryptUnprotectData(&in, NULL, NULL, NULL, NULL, 0, &out))
  {
    errorMessage = L"CryptUnprotectData failed (different user or machine)";
    return false;
  }

  const size_t size = (size_t)out.cbData;
  if ((size & 1) != 0)
  {
    memset(out.pbData, 0, size);
    LocalFree(out.pbData);
    errorMessage = L"Invalid password data";
    return false;
  }

  const unsigned charCount = (unsigned)(size / 2);
  password.Empty();
  {
    wchar_t *p = password.GetBuf(charCount);
    memcpy(p, out.pbData, size);
    p[charCount] = 0;
    password.ReleaseBuf_SetLen(charCount);
  }
  memset(out.pbData, 0, size);
  LocalFree(out.pbData);
  return true;
}

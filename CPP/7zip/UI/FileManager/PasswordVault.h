// PasswordVault.h

#ifndef ZIP7_INC_PASSWORD_VAULT_H
#define ZIP7_INC_PASSWORD_VAULT_H

#include "../../../Common/MyBuffer.h"
#include "../../../Common/MyString.h"
#include "../../../Common/MyVector.h"

struct CPasswordVaultEntry
{
  UString Name;
  CByteBuffer EncryptedPassword; // DPAPI ciphertext (CryptProtectData output)
};

class CPasswordVault
{
  CObjectVector<CPasswordVaultEntry> _entries;
  UString _path;
public:
  void SetPath(const UString &path) { _path = path; }

  CObjectVector<CPasswordVaultEntry> &Entries() { return _entries; }
  const CObjectVector<CPasswordVaultEntry> &Entries() const { return _entries; }

  // Returns the default vault file path: %APPDATA%\7-Zip\7zPasswordVault.dat
  static UString GetDefaultPath();

  bool Load(UString &errorMessage);
  bool Save(UString &errorMessage);

  // Returns entry index, or -1 when not found.
  int FindByName(const UString &name) const;

  static bool EncryptPassword(const UString &password, CByteBuffer &blob, UString &errorMessage);
  static bool DecryptPassword(const CByteBuffer &blob, UString &password, UString &errorMessage);
};

#endif

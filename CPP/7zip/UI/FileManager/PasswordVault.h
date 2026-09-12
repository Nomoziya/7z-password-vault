// PasswordVault.h

#ifndef ZIP7_INC_PASSWORD_VAULT_H
#define ZIP7_INC_PASSWORD_VAULT_H

#include "../../../Common/MyBuffer.h"
#include "../../../Common/MyString.h"
#include "../../../Common/MyVector.h"

#include "../../../Windows/FileIO.h"
#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/Edit.h"

#include "PasswordDialogRes.h"

struct CPasswordVaultEntry
{
  UString Name;
  UString Password; // plaintext, kept in memory only; encrypted on disk
};

class CPasswordVault
{
  CObjectVector<CPasswordVaultEntry> _entries;
  UString _path;
  bool _masterMode; // how the file was last saved

  bool Load_DPAPI(NWindows::NFile::NIO::CInFile &f, Byte version, UString &errorMessage);
  bool Load_Master(HWND parent, NWindows::NFile::NIO::CInFile &f, UString &errorMessage);
  bool Save_DPAPI(NWindows::NFile::NIO::COutFile &f, UString &errorMessage);
  bool Save_Master(NWindows::NFile::NIO::COutFile &f, UString &errorMessage);

  void SerializeEntries(CByteBuffer &out);
  bool ParseEntries(const Byte *data, size_t size, UString &errorMessage);

public:
  void SetPath(const UString &path) { _path = path; }
  const UString &GetPath() const { return _path; }

  CObjectVector<CPasswordVaultEntry> &Entries() { return _entries; }
  const CObjectVector<CPasswordVaultEntry> &Entries() const { return _entries; }

  static UString GetDefaultPath();
  static UString GetConfiguredPath();

  // parent is used only to show the master-password prompt when needed.
  bool Load(HWND parent, UString &errorMessage);
  bool Save(UString &errorMessage);

  int FindByName(const UString &name) const;

  // Master password session cache.
  // When the vault is encrypted with a master password, we cache the
  // master password for the process lifetime if "remember" is enabled.
  static void SetCachedMasterPassword(const UString &password);
  static void ClearCachedMasterPassword();
  static bool HaveCachedMasterPassword();
  static bool GetMasterPassword(HWND parent, UString &password, UString &errorMessage);
  static bool PromptForMasterPassword(HWND parent, UString &password, UString &errorMessage);
};

// Caption used by every message box the vault shows. Localized through the
// 7-Zip lang files (IDT_PASSWORD_VAULT_CAPTION) with a built-in fallback.
UString PasswordVault_GetCaption();

#endif

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

/* The configured location may point at a folder: the settings page has a Browse
   button that picks a folder, and the field is labelled "vault location". A folder
   means "keep the vault file in this folder", so the file name is appended - without
   this, saving over a folder made MoveFileEx fail with "cannot replace the vault
   file". A quoted path (pasted from Explorer) is unquoted, and surrounding spaces are
   trimmed. Anything else is returned unchanged, so a plain file path stays a file. */
UString PasswordVault_NormalizePath(const UString &path);

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
  /* The file exists but could not be read (locked, no permission, wrong account).
     Saving in that state would write the empty list in memory over the real file, so
     Save() refuses until a Load() succeeded. */
  bool _readFailed = false;
  /* Size and write time of the file as it was read, to notice that another process
     (7zFM and 7zG can both save) replaced it in the meantime. */
  unsigned long long _loadedSize = 0;
  unsigned long long _loadedWriteTime = 0;

  bool Load_DPAPI(NWindows::NFile::NIO::CInFile &f, Byte version, UString &errorMessage);
  bool Load_Master(HWND parent, NWindows::NFile::NIO::CInFile &f, UString &errorMessage);
  bool Save_DPAPI(NWindows::NFile::NIO::COutFile &f, UString &errorMessage);
  bool Save_Master(NWindows::NFile::NIO::COutFile &f, UString &errorMessage, HWND parent);

  void RememberFileState();
  void SerializeEntries(CByteBuffer &out);
  bool ParseEntries(const Byte *data, size_t size, UString &errorMessage);

public:
  void SetPath(const UString &path) { _path = PasswordVault_NormalizePath(path); }
  const UString &GetPath() const { return _path; }

  CObjectVector<CPasswordVaultEntry> &Entries() { return _entries; }
  const CObjectVector<CPasswordVaultEntry> &Entries() const { return _entries; }

  static UString GetDefaultPath();
  static UString GetConfiguredPath();

  /* The default location is the program folder (portable), so the vault does not
     take space on the system drive. Called once before the vault is loaded: when no
     path is configured and a vault still sits in %APPDATA%\7-Zip, that file is moved
     next to the program. Returns the message to show, or an empty string. */
  static UString AdoptPortableDefault();

  // parent is used only to show the master-password prompt when needed.
  bool Load(HWND parent, UString &errorMessage);
  /* parent is used only when the master password has to be asked for again
     (the "remember" setting is off); it must be a window of the calling dialog,
     otherwise the prompt would appear unowned and can end up behind it. */
  bool Save(UString &errorMessage, HWND parent = NULL);

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

/* Localized text. The fallback (Chinese) is used only when the loaded lang
   file has no string for that id, so every dialog and message box follows the
   7-Zip UI language. Available in both 7zFM and 7zG, because PasswordVault.cpp
   and PasswordVaultUi.cpp are linked into both. */
UString PasswordVault_GetText(UInt32 langID, const wchar_t *fallback);

// Caption used by every message box the vault shows. Localized through the
// 7-Zip lang files (IDT_PASSWORD_VAULT_CAPTION) with a built-in fallback.
UString PasswordVault_GetCaption();

#endif

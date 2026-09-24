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

// Owning string for vault secrets. Wipe the old value before replacement and
// on scope exit, including cancellation and exception paths.
class CVaultString: public UString
{
public:
  CVaultString() {}
  CVaultString(const UString &s): UString(s) {}
  CVaultString(const CVaultString &s): UString(s) {}
  void Wipe()
  {
    if (!IsEmpty()) ::SecureZeroMemory(Ptr_non_const(), (size_t)Len() * sizeof(wchar_t));
    Empty();
  }
  CVaultString &operator=(const UString &s)
  {
    if ((const UString *)this != &s) { Wipe(); UString::operator=(s); }
    return *this;
  }
  CVaultString &operator=(const CVaultString &s) { return operator=((const UString &)s); }
  ~CVaultString() { Wipe(); }
};

struct CPasswordVaultEntry
{
  CVaultString Name;
  CVaultString Password; // plaintext, kept in memory only; encrypted on disk

  CPasswordVaultEntry() {}
  CPasswordVaultEntry(const CPasswordVaultEntry &other):
      Name(other.Name), Password(other.Password) {}
  CPasswordVaultEntry &operator=(const CPasswordVaultEntry &other);
  ~CPasswordVaultEntry();
};

class CPasswordVault
{
  friend class CPasswordVaultRestore;
  HANDLE _session = INVALID_HANDLE_VALUE;
  void ReleaseSession();
  CObjectVector<CPasswordVaultEntry> _entries;
  CObjectVector<CPasswordVaultEntry> _baseline;
  CByteBuffer _loadedImage; // exact encrypted bytes, never a timestamp heuristic
  UString _path;
  bool _masterMode = false; // how the file was last saved
  /* The file exists but could not be read (locked, no permission, wrong account).
     Saving in that state would write the empty list in memory over the real file, so
     Save() refuses until a Load() succeeded. */
  bool _readFailed = true;
  /* Whether this object ever read a file: decides where the mode comes from and whether
     the file may be replaced. */
  bool _haveLoadedMode = false;
  bool _loadedExisted = false;
  bool _snapshotOnly = false;

  bool Load_DPAPI(NWindows::NFile::NIO::CInFile &f, Byte version, UString &errorMessage);
  bool Load_Master(HWND parent, NWindows::NFile::NIO::CInFile &f, UString &errorMessage);
  bool Save_DPAPI(NWindows::NFile::NIO::COutFile &f, UString &errorMessage);
  bool Save_Master(NWindows::NFile::NIO::COutFile &f, UString &errorMessage, HWND parent);

  bool SaveFile(UString &errorMessage, HWND parent, int modeOverride,
      const CByteBuffer &previousImage, bool existed);
  bool SerializeEntries(CByteBuffer &out, UString &errorMessage);
  bool ParseEntries(const Byte *data, size_t size, UString &errorMessage);

public:
  CPasswordVault() {}
  CPasswordVault(const CPasswordVault &) = delete;
  CPasswordVault &operator=(const CPasswordVault &) = delete;
  ~CPasswordVault();
  void ClearEntries();
  bool EnsureAuthenticated(HWND parent, UString &errorMessage, bool *reloaded = NULL);

  void SetPath(const UString &path) { ReleaseSession(); ClearEntries(); _baseline.Clear(); _loadedImage.Free(); _readFailed = true; _path = PasswordVault_NormalizePath(path); }
  const UString &GetPath() const { return _path; }

  CObjectVector<CPasswordVaultEntry> &Entries() { return _entries; }
  const CObjectVector<CPasswordVaultEntry> &Entries() const { return _entries; }

  static bool settings_DefaultMaster();
  static UString GetDefaultPath();
  static UString GetConfiguredPath();

  /* New vaults default to the current user's APPDATA directory. An existing
     program-directory vault is still discovered for portable compatibility, but
     sensitive data is never moved there automatically. */
  static UString AdoptPortableDefault();

  /* No location was chosen yet and BOTH default vault files exist. The program cannot
     guess which one the user means, so the UI asks once and records the answer
     with SetConfiguredPath. Returns false when there is nothing to ask. */
  static bool GetTwoDefaults(UString &portable, UString &roaming);

  /* Record a location as if the user had typed it in the settings page: the two
     defaults are never asked about again and nothing is moved. */
  static void SetConfiguredPath(const UString &path);

  // parent is used only to show the master-password prompt when needed.
  // snapshotOnly is for import/restore validation, never a live editable session.
  // It works on read-only source media and Save() explicitly rejects it.
  bool Load(HWND parent, UString &errorMessage, bool snapshotOnly = false);
  /* parent is used only when the master password has to be asked for again
     (the "remember" setting is off); it must be a window of the calling dialog,
     otherwise the prompt would appear unowned and can end up behind it. */
  /* modeOverride: -1 keep (the file decides), 0 DPAPI, 1 master password. */
  bool Save(UString &errorMessage, HWND parent = NULL, int modeOverride = -1);

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

// A single-use authenticated restore proposal. It never calls ordinary Save()
// (which would rotate away the recovery source). Secrets stay in memory only.
class CPasswordVaultRestore
{
  CPasswordVault _backup;
  UString _path, _canonical;
  CByteBuffer _original;
  bool _existed = false, _ready = false;
public:
  UString SafetyCopyPath;
  UString CleanupWarning; // Secondary failure; never changes Committed/SystemError.
  UString Stage;
  DWORD SystemError = 0;
  FILETIME BackupTime = {};
  bool Committed = false;
  ~CPasswordVaultRestore() { CPasswordVault::ClearCachedMasterPassword(); }
  bool Prepare(const UString &path, HWND parent, UString &error);
  bool Commit(UString &error);
  bool MasterMode() const { return _backup._masterMode; }
  unsigned EntryCount() const { return _backup.Entries().Size(); }
  bool AlreadyCurrent() const { return _ready && _existed && _original == _backup._loadedImage; }
private:
  bool Fail(const wchar_t *stage, DWORD code, UString &error);
};

/* Localized text. The fallback (Chinese) is used only when the loaded lang
   file has no string for that id, so every dialog and message box follows the
   7-Zip UI language. Available in both 7zFM and 7zG, because PasswordVault.cpp
   and PasswordVaultUi.cpp are linked into both. */
UString PasswordVault_GetText(UInt32 langID, const wchar_t *fallback);

// Caption used by every message box the vault shows. Localized through the
// 7-Zip lang files (IDT_PASSWORD_VAULT_CAPTION) with a built-in fallback.
UString PasswordVault_GetCaption();

// Read-only detection of interrupted restore material for this exact vault.
UString PasswordVault_FindRestoreMaterial(const UString &path);
void PasswordVault_NotifyRestoreMaterial(HWND parent, const UString &path);

#endif

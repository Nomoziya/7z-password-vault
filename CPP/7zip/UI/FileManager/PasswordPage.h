// PasswordPage.h

#ifndef ZIP7_INC_PASSWORD_PAGE_H
#define ZIP7_INC_PASSWORD_PAGE_H

#include "../../../Windows/Control/PropertyPage.h"
#include "../../../Windows/Control/Edit.h"

class CPasswordPage: public NWindows::NControl::CPropertyPage
{
  NWindows::NControl::CEdit _vaultPathEdit;
  bool _needSave;
  bool _initMode;
  /* set while the page itself writes into the vault path box, so the resulting
     EN_CHANGE does not mark the page as modified again right after a successful save */
  bool _suppressChange;
  UString _oldVaultPath;
  bool _oldUseMaster;

  virtual bool OnInit() Z7_override;
  virtual LONG OnApply() Z7_override;
  virtual bool OnCommand(unsigned code, unsigned itemID, LPARAM param) Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;

  void ModifiedEvent();
  UString GetVaultPathFromUi();
  void OnBrowse();
  void OnSetMasterPassword();
  void OnClearMasterPassword();
  void OnExport();
  void OnImport();
public:
};

#endif

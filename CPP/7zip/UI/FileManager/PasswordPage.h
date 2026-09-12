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
  UString _oldVaultPath;
  bool _oldUseMaster;

  virtual bool OnInit() Z7_override;
  virtual LONG OnApply() Z7_override;
  virtual bool OnCommand(unsigned code, unsigned itemID, LPARAM param) Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;

  void ModifiedEvent();
  void OnBrowse();
  void OnSetMasterPassword();
public:
};

#endif

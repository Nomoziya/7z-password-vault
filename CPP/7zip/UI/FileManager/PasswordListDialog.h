// PasswordListDialog.h

#ifndef ZIP7_INC_PASSWORD_LIST_DIALOG_H
#define ZIP7_INC_PASSWORD_LIST_DIALOG_H

#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/ListView.h"

#include "PasswordDialogRes.h"
#include "PasswordVault.h"

/* Window that lists the saved passwords in a 3 column table:
     Name | Password | Delete
   - single click on Name/Password -> types that password into the target edit
   - double click or right click (per the setting) -> edits the entry
   - click on the Delete cell -> deletes the entry (with confirmation)

   The list view is subclassed and the mouse messages are hit-tested directly.
   This control does not deliver NM_CLICK notifications, so the documented
   notification cannot be relied on. */
class CPasswordListDialog: public NWindows::NControl::CModalDialog
{
  /* Nested classes are members, so CList may use the private members below. */
  class CList: public NWindows::NControl::CListView2
  {
    CPasswordListDialog *_dialog;
  public:
    CList(CPasswordListDialog *dialog): _dialog(dialog) {}
    virtual LRESULT OnMessage(UINT message, WPARAM wParam, LPARAM lParam) Z7_override;
  };

  CList _list;
  CPasswordVault *_vault;
  HWND _targetEdit;
  bool _editByRightClick;
  /* Mask the password column unless the user asked to see the passwords.
     Filling is unaffected: the entry is read from the vault, not from the cell. */
  bool _showPasswords;
  bool _changed;
  /* Index whose Delete cell was pressed. The deletion itself runs from a posted
     command, never from the click message itself. */
  int _pendingDeleteItem;

  virtual bool OnInit() Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;

  void FillList();
  void ShowDefaultHint();
  void ShowFilledHint(const UString &name);
  void PickItem(int index);
  void EditItem(int index);
  void DeleteItem(int index);

  void OnListLeftDown(int item, int subItem);
  void OnListDoubleClick(int item, int subItem);
  void OnListRightDown(int item, int subItem);
public:
  CPasswordListDialog(CPasswordVault *vault, HWND targetEdit);

  bool EntriesChanged() const { return _changed; }

  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD_LIST, parentWindow); }
};

#endif

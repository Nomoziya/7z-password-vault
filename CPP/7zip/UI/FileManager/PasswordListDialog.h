// PasswordListDialog.h

#ifndef ZIP7_INC_PASSWORD_LIST_DIALOG_H
#define ZIP7_INC_PASSWORD_LIST_DIALOG_H

#include "../../../Windows/Control/Dialog.h"
#include "../../../Windows/Control/ListView.h"

#include "PasswordDialogRes.h"
#include "PasswordVault.h"

/* Columns of the saved password list. */
enum
{
  kColName = 0,
  kColValue = 1
};

/* Window that lists the saved passwords:

     Name | Password
     [ Fill password ]  [ Edit... ]  [x] Show passwords          [ Close ]

   The list is an ordinary report list view, drawn by the system exactly like the
   file panels in the file manager, and the two actions are ordinary push buttons,
   so they look and behave like every other 7-Zip button. They work on the row
   that is selected; a double click on a row does the same as Fill.

   The list view is subclassed and its mouse messages are hit tested directly,
   because this control does not deliver NM_CLICK notifications. A click never
   runs its action inline: the actions are posted as one command and run from the
   message loop, so no modal window is opened while the mouse is captured. */
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
  /* Mask the password column unless the user asked to see the passwords.
     Filling is unaffected: the entry is read from the vault, not from the cell. */
  bool _showPasswords;
  /* Unnamed entries have nothing in the name column, so the option can show their
     password instead of dots to make them findable. The plaintext only exists after
     the vault was unlocked, so a master password protected vault shows nothing
     until it has been unlocked. */
  bool _showUnnamedPassword;
  bool _closeAfterFill;
  bool _changed;

  virtual bool OnInit() Z7_override;
  virtual bool OnButtonClicked(unsigned buttonID, HWND buttonHWND) Z7_override;

  void FillList();
  void ShowDefaultHint();
  void ShowFilledHint(const UString &name);
  void UpdateColumnWidths();
  void FillItem(int index);
  void EditItem(int index);
  int GetSelectedItem() const;
  void UpdateButtons();
  void SelectRow(int row);

public:
  CPasswordListDialog(CPasswordVault *vault, HWND targetEdit);

  bool EntriesChanged() const { return _changed; }

  INT_PTR Create(HWND parentWindow = NULL) { return CModalDialog::Create(IDD_PASSWORD_LIST, parentWindow); }
};

#endif

// PasswordListDialog.cpp

#include "StdAfx.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "../Common/ZipRegistry.h"

#include "PasswordDialog.h"   // CPasswordEditDialog
#include "PasswordListDialog.h"

using namespace NWindows;

#ifdef Z7_LANG
static const UInt32 kLangIDs[] =
{
  IDT_PASSWORD_LIST_HINT,
  IDB_PASSWORD_LIST_CLOSE
};
#endif

enum
{
  kColName = 0,
  kColValue = 1,
  kColDelete = 2
};

/* Private command id. A click on the Delete cell posts it, so the confirmation
   box is opened from the message loop and never while the mouse is captured.
   WM_LBUTTONUP cannot be used for this: the list view captures the mouse on
   button-down and swallows the matching button-up, so it never arrives. */
enum
{
  kCmdDeleteRow = 3827
};

static UString GetLangText(UInt32 langID, const wchar_t *fallback)
{
  #ifdef Z7_LANG
  const UString s = LangString(langID);
  if (!s.IsEmpty())
    return s;
  #endif
  return UString(fallback);
}

static void VaultErrorMessage(HWND wnd, const UString &message)
{
  if (message.IsEmpty())
    return;
  ::MessageBoxW(wnd, message, PasswordVault_GetCaption(), MB_ICONERROR | MB_OK);
}

// ---- subclassed list view ----

LRESULT CPasswordListDialog::CList::OnMessage(UINT message, WPARAM wParam, LPARAM lParam)
{
  switch (message)
  {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    {
      /* This control does not send NM_CLICK, so hit-test the click point here. */
      LVHITTESTINFO hti;
      hti.pt.x = (short)LOWORD(lParam);
      hti.pt.y = (short)HIWORD(lParam);
      hti.flags = 0;
      const int item = ListView_SubItemHitTest(*this, &hti);
      const int sub = hti.iSubItem;

      if (message == WM_LBUTTONDOWN)
        _dialog->OnListLeftDown(item, sub);
      else if (message == WM_LBUTTONDBLCLK)
        _dialog->OnListDoubleClick(item, sub);
      else
        _dialog->OnListRightDown(item, sub);
      break;
    }
    default:
      break;
  }
  return CListView2::OnMessage(message, wParam, lParam);
}

void CPasswordListDialog::OnListLeftDown(int item, int subItem)
{
  if (item < 0)
    return;

  if (subItem == kColDelete)
  {
    /* Defer the confirmation box to the message loop. */
    _pendingDeleteItem = item;
    PostMsg(WM_COMMAND, MAKEWPARAM(kCmdDeleteRow, 0), 0);
    return;
  }
  PickItem(item);
}

void CPasswordListDialog::OnListDoubleClick(int item, int subItem)
{
  if (item < 0)
    return;

  if (subItem == kColDelete)
    return;

  /* Exactly one of double-click / right-click edits, per the setting. */
  if (_editByRightClick)
    PickItem(item);
  else
    EditItem(item);
}

void CPasswordListDialog::OnListRightDown(int item, int subItem)
{
  if (item < 0 || subItem == kColDelete)
    return;
  if (_editByRightClick)
    EditItem(item);
}

// ---- dialog ----

CPasswordListDialog::CPasswordListDialog(CPasswordVault *vault, HWND targetEdit):
    _list(this),
    _vault(vault),
    _targetEdit(targetEdit),
    _editByRightClick(false),
    _changed(false),
    _pendingDeleteItem(-1)
{
}

bool CPasswordListDialog::OnInit()
{
  #ifdef Z7_LANG
  LangSetWindowText(*this, IDD_PASSWORD_LIST);
  LangSetDlgItems(*this, kLangIDs, Z7_ARRAY_SIZE(kLangIDs));
  #endif

  NPasswordVault::CInfo settings;
  settings.Load();
  _editByRightClick = settings.EditByRightClick;

  _list.Attach(GetItem(IDL_PASSWORD_LIST));
  _list.SetExtendedListViewStyle(LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES,
                                 LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);
  _list.SetWindowProc();   /* subclass: we need the raw mouse messages */

  _list.InsertColumn(kColName,   GetLangText(IDT_PASSWORD_COL_NAME,  L"名称"), 150);
  _list.InsertColumn(kColValue,  GetLangText(IDT_PASSWORD_COL_VALUE, L"密码"), 150);
  _list.InsertColumn(kColDelete, GetLangText(IDT_PASSWORD_COL_DEL,   L"删除"), 50);

  FillList();
  ShowDefaultHint();
  return CModalDialog::OnInit();
}

void CPasswordListDialog::FillList()
{
  _list.DeleteAllItems();
  _pendingDeleteItem = -1;
  if (!_vault)
    return;

  const CObjectVector<CPasswordVaultEntry> &entries = _vault->Entries();
  FOR_VECTOR(i, entries)
  {
    const CPasswordVaultEntry &entry = entries[i];
    const int index = _list.InsertItem((unsigned)i, entry.Name);
    if (index >= 0)
    {
      _list.SetSubItem((unsigned)index, kColValue, entry.Password);
      _list.SetSubItem((unsigned)index, kColDelete, GetLangText(IDT_PASSWORD_COL_DEL, L"删除"));
    }
  }
}

void CPasswordListDialog::ShowDefaultHint()
{
  #ifdef Z7_LANG
  const UString s = LangString(IDT_PASSWORD_LIST_HINT);
  if (!s.IsEmpty())
    SetItemText(IDT_PASSWORD_LIST_HINT, s);
  #endif
}

void CPasswordListDialog::ShowFilledHint(const UString &name)
{
  UString s = GetLangText(IDT_PASSWORD_LIST_FILLED, L"已填入：");
  s += name;
  SetItemText(IDT_PASSWORD_LIST_HINT, s);
}

void CPasswordListDialog::PickItem(int index)
{
  if (!_vault || (unsigned)index >= _vault->Entries().Size())
    return;

  const CPasswordVaultEntry &entry = _vault->Entries()[(unsigned)index];
  if (_targetEdit)
    ::SetWindowTextW(_targetEdit, entry.Password);
  ShowFilledHint(entry.Name);
}

void CPasswordListDialog::EditItem(int index)
{
  if (!_vault || (unsigned)index >= _vault->Entries().Size())
    return;

  CPasswordVaultEntry &entry = _vault->Entries()[(unsigned)index];

  CPasswordEditDialog dialog(false);
  dialog.Name = entry.Name;
  dialog.Value = entry.Password;
  if (dialog.Create(*this) != IDOK)
    return;

  UString name = dialog.Name;
  name.Trim();
  if (name.IsEmpty())
    name = PasswordVault_MakeDefaultName(*_vault);

  entry.Name = name;
  entry.Password = dialog.Value;

  UString error;
  if (!_vault->Save(error))
  {
    VaultErrorMessage(*this, error);
    return;
  }
  _changed = true;
  FillList();
  ShowDefaultHint();
}

void CPasswordListDialog::DeleteItem(int index)
{
  if (!_vault || (unsigned)index >= _vault->Entries().Size())
    return;

  UString message = GetLangText(IDT_PASSWORD_LIST_DELETE_Q, L"确定要删除这条已保存的密码吗？");
  message += L"\r\n\r\n";
  message += _vault->Entries()[(unsigned)index].Name;

  if (::MessageBoxW(*this, message, PasswordVault_GetCaption(), MB_ICONQUESTION | MB_YESNO) != IDYES)
    return;

  _vault->Entries().Delete((unsigned)index);

  UString error;
  if (!_vault->Save(error))
  {
    VaultErrorMessage(*this, error);
    return;
  }
  _changed = true;
  FillList();
  ShowDefaultHint();
}

bool CPasswordListDialog::OnButtonClicked(unsigned buttonID, HWND buttonHWND)
{
  if (buttonID == kCmdDeleteRow)
  {
    const int index = _pendingDeleteItem;
    _pendingDeleteItem = -1;   /* a double click must not delete twice */
    if (index >= 0)
      DeleteItem(index);
    return true;
  }
  if (buttonID == IDB_PASSWORD_LIST_CLOSE)
  {
    End(IDCANCEL);
    return true;
  }
  return CModalDialog::OnButtonClicked(buttonID, buttonHWND);
}

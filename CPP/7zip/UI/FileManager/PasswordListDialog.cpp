// PasswordListDialog.cpp

#include "StdAfx.h"

#ifdef Z7_LANG
#include "LangUtils.h"
#endif

#include "../Common/ZipRegistry.h"

#include "PasswordDialog.h"   // CPasswordEditDialog
#include "PasswordListDialog.h"
#include "PasswordVaultUi.h"

using namespace NWindows;

#ifdef Z7_LANG
static const UInt32 kLangIDs[] =
{
  IDT_PASSWORD_LIST_HINT,
  IDB_PASSWORD_FILL,
  IDB_PASSWORD_EDIT,
  IDX_PASSWORD_LIST_SHOW,
  IDB_PASSWORD_LIST_CLOSE
};
#endif

/* Shown in the password column while the passwords are masked. A fixed length
   does not leak how long the stored password is. */
static const wchar_t * const kMaskedPassword = L"\x2022\x2022\x2022\x2022\x2022\x2022\x2022\x2022";

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
    {
      /* Clicking a row selects it; the buttons work on the selection, so their
         state has to follow. The control does not report LVN_ITEMCHANGED to this
         dialog, so this is done from the click itself. */
      const LRESULT res = CListView2::OnMessage(message, wParam, lParam);
      _dialog->UpdateButtons();
      return res;
    }
    case WM_LBUTTONDBLCLK:
    {
      /* This control does not send NM_DBLCLK either, so hit-test the point. */
      LVHITTESTINFO hti;
      hti.pt.x = (short)LOWORD(lParam);
      hti.pt.y = (short)HIWORD(lParam);
      hti.flags = 0;
      const int item = ListView_SubItemHitTest(*this, &hti);
      if (item >= 0)
      {
        _dialog->FillItem(item);
        return 0;
      }
      break;
    }
    default:
      break;
  }
  return CListView2::OnMessage(message, wParam, lParam);
}

// ---- dialog ----

CPasswordListDialog::CPasswordListDialog(CPasswordVault *vault, HWND targetEdit):
    _list(this),
    _vault(vault),
    _targetEdit(targetEdit),
    _showPasswords(false),
    _showUnnamedPassword(false),
    _closeAfterFill(true),
    _changed(false)
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
  _showPasswords = settings.ShowPasswordInList;
  _showUnnamedPassword = settings.ShowPasswordForUnnamed;
  _closeAfterFill = settings.CloseAfterFill;
  CheckButton(IDX_PASSWORD_LIST_SHOW, _showPasswords);

  _list.Attach(GetItem(IDL_PASSWORD_LIST));
  _list.SetExtendedListViewStyle(LVS_EX_FULLROWSELECT, LVS_EX_FULLROWSELECT);
  _list.SetWindowProc();   /* subclass: we need the raw mouse messages */

  /* Column widths are pixels and the content decides them; they are set in
     UpdateColumnWidths once the rows exist. */
  _list.InsertColumn(kColName,  PasswordVault_GetText(IDT_PASSWORD_COL_NAME,  L"名称"), 200);
  _list.InsertColumn(kColValue, PasswordVault_GetText(IDT_PASSWORD_COL_VALUE, L"密码"), 200);

  FillList();
  ShowDefaultHint();
  return CModalDialog::OnInit();
}

void CPasswordListDialog::FillList()
{
  _list.DeleteAllItems();
  if (!_vault)
  {
    UpdateButtons();
    return;
  }

  const CObjectVector<CPasswordVaultEntry> &entries = _vault->Entries();
  FOR_VECTOR(i, entries)
  {
    const CPasswordVaultEntry &entry = entries[i];
    const int index = _list.InsertItem((unsigned)i, entry.Name);
    if (index >= 0)
    {
      /* The password cell is masked unless the user asked to see all passwords, or
         asked to see the ones of unnamed entries and this entry has no name.
         Filling still works: FillItem reads the entry, never the cell text. */
      const bool showThis = _showPasswords ||
          (_showUnnamedPassword && entry.Name.IsEmpty());
      _list.SetSubItem((unsigned)index, kColValue,
          showThis ? entry.Password : UString(kMaskedPassword));
    }
  }

  /* Selecting the first row makes the buttons usable straight away. */
  if (!_vault->Entries().IsEmpty())
    SelectRow(0);
  UpdateButtons();
  UpdateColumnWidths();
}

/* The name column is sized to its content, exactly like the columns of the file
   manager panels, and the password column gets everything that is left. A short
   name therefore leaves a wide password column instead of wasting the space on an
   empty name field, which is what matters when a long password is shown. */
void CPasswordListDialog::UpdateColumnWidths()
{
  RECT cr;
  if (!::GetClientRect(_list, &cr) || cr.right <= cr.left)
    return;
  const int clientW = (int)(cr.right - cr.left);
  if (clientW < 80)
    return;

  ListView_SetColumnWidth(_list, kColName, LVSCW_AUTOSIZE_USEHEADER);
  int nameW = (int)::SendMessage(_list, LVM_GETCOLUMNWIDTH, (WPARAM)kColName, 0);

  /* A very long name must not squeeze the password out of the window. */
  const int maxNameW = clientW * 3 / 5;
  if (nameW > maxNameW)
    nameW = maxNameW;
  if (nameW < 40)
    nameW = 40;

  int valueW = clientW - nameW - 4;
  if (valueW < 40)
    valueW = 40;

  ListView_SetColumnWidth(_list, kColName, nameW);
  ListView_SetColumnWidth(_list, kColValue, valueW);
}

int CPasswordListDialog::GetSelectedItem() const
{
  return (int)::SendMessage(_list, LVM_GETNEXTITEM, (WPARAM)(INT)-1, MAKELPARAM(LVNI_SELECTED, 0));
}

void CPasswordListDialog::SelectRow(int row)
{
  LVITEMW item;
  item.stateMask = LVIS_SELECTED | LVIS_FOCUSED;
  item.state = LVIS_SELECTED | LVIS_FOCUSED;
  ::SendMessageW(_list, LVM_SETITEMSTATE, (WPARAM)row, (LPARAM)&item);
  ::SendMessage(_list, LVM_ENSUREVISIBLE, (WPARAM)row, FALSE);
}

void CPasswordListDialog::UpdateButtons()
{
  const bool hasSelection = (GetSelectedItem() >= 0);
  EnableItem(IDB_PASSWORD_FILL, hasSelection);
  EnableItem(IDB_PASSWORD_EDIT, hasSelection);
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
  UString s = PasswordVault_GetText(IDT_PASSWORD_LIST_FILLED, L"已填入：");
  if (!s.IsEmpty())
  {
    /* "Filled in:" needs a separating space, "已填入：" must not get one. */
    const wchar_t c = s.Back();
    if (c != L' ' && c != L':' && c != L'：')
      s.Add_Space();
  }
  s += name;
  SetItemText(IDT_PASSWORD_LIST_HINT, s);
}

void CPasswordListDialog::FillItem(int index)
{
  if (!_vault || (unsigned)index >= _vault->Entries().Size())
    return;

  const CPasswordVaultEntry &entry = _vault->Entries()[(unsigned)index];
  if (_targetEdit)
    ::SetWindowTextW(_targetEdit, entry.Password);
  ShowFilledHint(entry.Name);

  /* Closing is what the user asked for by default: the password is in the
     input box and the window has done its job. */
  if (_closeAfterFill)
    End(IDCANCEL);
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

  if (dialog.Deleted)
  {
    _vault->Entries().Delete((unsigned)index);
  }
  else
  {
    UString name = dialog.Name;
    name.Trim();
    /* An empty name is allowed and stays empty: an unnamed entry must not be
       renamed behind the user's back. */
    entry.Name = name;
    entry.Password = dialog.Value;
  }

  UString error;
  if (!_vault->Save(error, *this))
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
  if (buttonID == IDX_PASSWORD_LIST_SHOW)
  {
    _showPasswords = IsButtonCheckedBool(IDX_PASSWORD_LIST_SHOW);
    FillList();
    /* The window is only a viewer; the setting itself lives in the options. */
    return true;
  }
  if (buttonID == IDB_PASSWORD_FILL)
  {
    FillItem(GetSelectedItem());
    return true;
  }
  if (buttonID == IDB_PASSWORD_EDIT)
  {
    EditItem(GetSelectedItem());
    return true;
  }
  if (buttonID == IDB_PASSWORD_LIST_CLOSE)
  {
    End(IDCANCEL);
    return true;
  }
  return CModalDialog::OnButtonClicked(buttonID, buttonHWND);
}

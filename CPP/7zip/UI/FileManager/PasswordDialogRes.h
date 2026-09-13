#define IDD_PASSWORD        3800
#define IDT_PASSWORD_ENTER  3801
#define IDX_PASSWORD_SHOW   3803

#define IDE_PASSWORD_PASSWORD  120

/* main password dialog */
#define IDB_PASSWORD_LIST   3808   /* button: "saved passwords..." */
#define IDB_PASSWORD_NEW    3809   /* button: "new password..."   */

/* new / edit one saved password (dialog resource id + its default title) */
#define IDD_PASSWORD_EDIT   3810
#define IDT_PASSWORD_NAME   3811
#define IDT_PASSWORD_VALUE  3812
#define IDE_PASSWORD_NAME   121
#define IDE_PASSWORD_VALUE  122

/* master password prompt */
#define IDD_PASSWORD_MASTER 3813
#define IDT_PASSWORD_MASTER 3814
#define IDE_PASSWORD_MASTER 123

/* saved password list window */
#define IDD_PASSWORD_LIST       3815
#define IDT_PASSWORD_LIST_HINT  3816
#define IDB_PASSWORD_LIST_CLOSE 3817
#define IDT_PASSWORD_COL_NAME   3818
#define IDT_PASSWORD_COL_VALUE  3819
#define IDT_PASSWORD_COL_DEL    3820   /* unused: a row now offers Edit instead */
#define IDL_PASSWORD_LIST       124

/* title used when the edit dialog is opened for an existing entry */
#define IDD_PASSWORD_EDIT_TITLE 3821

/* extra text used by the password list window */
#define IDT_PASSWORD_LIST_FILLED   3822
#define IDT_PASSWORD_LIST_DELETE_Q 3823

/* extra text used by the password dialog */
#define IDT_PASSWORD_DEFAULT_NAME  3824   /* unused: unnamed entries stay unnamed */
#define IDT_PASSWORD_SAVE_NEW_Q    3825
#define IDT_PASSWORD_AUTOTYPE_Q    3826

/* caption of every message box the vault shows (localized) */
#define IDT_PASSWORD_VAULT_CAPTION 3828

/* "show passwords" checkbox inside the saved password list window */
#define IDX_PASSWORD_LIST_SHOW 3829

/* delete button of the edit window (only shown for a stored entry) */
#define IDB_PASSWORD_DELETE    3830

/* shown in place of the name of an entry that has no name (unused: an unnamed
   entry simply has an empty name cell) */
#define IDT_PASSWORD_LIST_UNNAMED 3833

/* actions of the saved password list window: real buttons that work on the
   selected row */
#define IDB_PASSWORD_FILL      3831
#define IDB_PASSWORD_EDIT      3832

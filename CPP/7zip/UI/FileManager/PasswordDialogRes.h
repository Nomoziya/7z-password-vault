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

/* message boxes of the settings page (localized, see PasswordVault_GetText) */
#define IDT_PASSWORD_PICK_FOLDER        3834
#define IDT_PASSWORD_MASTER_EMPTY       3835
#define IDT_PASSWORD_MASTER_MISMATCH    3836
#define IDT_PASSWORD_CLEAR_MASTER_Q     3837
#define IDT_PASSWORD_CLEAR_MASTER_DONE  3838
#define IDT_PASSWORD_NO_VAULT_FILE      3839
#define IDT_PASSWORD_EXPORT_TITLE       3840
#define IDT_PASSWORD_FILE_FILTER        3841
#define IDT_PASSWORD_EXPORT_FAILED      3842
#define IDT_PASSWORD_EXPORT_DONE        3843
#define IDT_PASSWORD_IMPORT_TITLE       3844
/* {0} = added, {1} = updated */
#define IDT_PASSWORD_IMPORT_DONE        3845
/* {0} = new path, {1} = old path */
#define IDT_PASSWORD_MOVED_Q            3846

/* vault error messages */
#define IDT_PASSWORD_ERR_MAGIC          3847
#define IDT_PASSWORD_ERR_VERSION        3848
#define IDT_PASSWORD_ERR_FILE           3849
#define IDT_PASSWORD_ERR_CREATE         3850
#define IDT_PASSWORD_ERR_WRITE          3851
#define IDT_PASSWORD_ERR_REPLACE        3852
#define IDT_PASSWORD_ERR_DATA           3853
#define IDT_PASSWORD_ERR_ENTRY          3854
#define IDT_PASSWORD_ERR_DECRYPT        3855
#define IDT_PASSWORD_ERR_PASSWORD       3856
#define IDT_PASSWORD_ERR_ENCRYPT        3857
#define IDT_PASSWORD_ERR_KDF            3858
#define IDT_PASSWORD_ERR_MASTER         3859
#define IDT_PASSWORD_ERR_RANDOM         3860

/* shown once when an old vault is moved next to the program (portable default) */
#define IDT_PASSWORD_MOVED_TO_PORTABLE  3861

/* the vault exists but cannot be opened (locked, no permission, ...) - not "empty" */
#define IDT_PASSWORD_ERR_OPEN           3862

/* the file was replaced by another window after it had been read */
#define IDT_PASSWORD_ERR_CHANGED        3863

/* the location cannot be changed while the current vault is unreadable */
#define IDT_PASSWORD_PATH_NEEDS_VAULT   3864

/* asked once when both default vault files exist (program folder and %APPDATA%) */
#define IDT_PASSWORD_TWO_VAULTS_Q       3865
/* confirmed after the answer: which file is used from now on, and where the other
   one stays */
#define IDT_PASSWORD_USING_PORTABLE     3866
#define IDT_PASSWORD_USING_ROAMING      3867

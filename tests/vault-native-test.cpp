// Exercise production vault code with real Windows crypto/files/mutexes.
// Only settings and dialogs are stubbed: no real vault or user settings touched.
#include "../CPP/7zip/UI/FileManager/StdAfx.h"
#include <windows.h>
#include <wincrypt.h>
#include <dpapi.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <aclapi.h>
#include <stdio.h>
#include <string>
#include <vector>
#include "../CPP/7zip/UI/FileManager/PasswordVault.h"
#include "../CPP/7zip/UI/Common/ZipRegistry.h"
#include "../CPP/Common/Lang.h"
static int fault = 0;
static DWORD protectError = 0;
static unsigned flushCalls = 0, moveCalls = 0;
static BOOL TestProtect(DATA_BLOB *in, LPCWSTR description, DATA_BLOB *entropy,
    PVOID reserved, CRYPTPROTECT_PROMPTSTRUCT *prompt, DWORD flags, DATA_BLOB *out) {
  if(fault==5) { SetLastError(ERROR_INVALID_DATA); return FALSE; }
  const BOOL ok=CryptProtectData(in,description,entropy,reserved,prompt,flags,out);
  if(!ok) { protectError=GetLastError(); fprintf(stderr,"DIAGNOSTIC: stage=CryptProtectData error=%lu\n",protectError); SetLastError(protectError); }
  return ok;
}
static bool rememberMaster = true;
static bool useMasterSetting = false;
static const wchar_t *scriptedMaster = NULL;
static UString fixtureRoot;
static UString configuredPath;
static bool CreateTestSymlink(const UString &link, const UString &target) {
  typedef BOOLEAN (WINAPI *CreateLink)(LPCWSTR,LPCWSTR,DWORD);
  const CreateLink createLink=(CreateLink)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"CreateSymbolicLinkW");
  if(!createLink) { SetLastError(ERROR_CALL_NOT_IMPLEMENTED); return false; }
  return createLink(link,target,2)!=0;
}
static bool DenyCurrentUserAccess(const UString &path, DWORD mask, PSECURITY_DESCRIPTOR &original) {
  original=NULL;
  PACL oldDacl=NULL;
  DWORD status=GetNamedSecurityInfoW((LPWSTR)(LPCWSTR)path,SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION,NULL,NULL,&oldDacl,NULL,&original);
  if(status!=ERROR_SUCCESS) { SetLastError(status); return false; }
  HANDLE token=NULL;
  if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token)) { LocalFree(original); original=NULL; return false; }
  DWORD needed=0;
  GetTokenInformation(token,TokenUser,NULL,0,&needed);
  std::vector<BYTE> tokenBuffer(needed);
  if(!needed || !GetTokenInformation(token,TokenUser,tokenBuffer.data(),needed,&needed)) {
    CloseHandle(token); LocalFree(original); original=NULL; return false;
  }
  CloseHandle(token);
  PTOKEN_USER user=(PTOKEN_USER)tokenBuffer.data();
  EXPLICIT_ACCESSW deny={};
  deny.grfAccessPermissions=mask;
  deny.grfAccessMode=DENY_ACCESS;
  deny.grfInheritance=NO_INHERITANCE;
  deny.Trustee.TrusteeForm=TRUSTEE_IS_SID;
  deny.Trustee.TrusteeType=TRUSTEE_IS_USER;
  deny.Trustee.ptstrName=(LPWSTR)user->User.Sid;
  PACL newDacl=NULL;
  status=SetEntriesInAclW(1,&deny,oldDacl,&newDacl);
  if(status!=ERROR_SUCCESS) { SetLastError(status); LocalFree(original); original=NULL; return false; }
  status=SetNamedSecurityInfoW((LPWSTR)(LPCWSTR)path,SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION,NULL,NULL,newDacl,NULL);
  LocalFree(newDacl);
  if(status!=ERROR_SUCCESS) { SetLastError(status); LocalFree(original); original=NULL; return false; }
  return true;
}
static bool RestoreDacl(const UString &path, PSECURITY_DESCRIPTOR original) {
  if(!original) return true;
  BOOL present=FALSE,defaulted=FALSE;
  PACL dacl=NULL;
  const bool got=GetSecurityDescriptorDacl(original,&present,&dacl,&defaulted)!=0;
  DWORD status=got ? SetNamedSecurityInfoW((LPWSTR)(LPCWSTR)path,SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION,NULL,NULL,present?dacl:NULL,NULL) : GetLastError();
  LocalFree(original);
  if(status!=ERROR_SUCCESS) { SetLastError(status); return false; }
  return true;
}
static HRESULT TestFolder(HWND, int, HANDLE, DWORD, LPWSTR out) {
  const UString p=fixtureRoot+L"\\appdata"; wcscpy(out,p); return S_OK;
}
static DWORD TestModule(HMODULE, LPWSTR out, DWORD n) {
  const UString p=fixtureRoot+L"\\portable\\7zFM.exe";
  if(p.Len()+1>n) return n; wcscpy(out,p); return p.Len();
}
static BOOL TestFlush(HANDLE h) {
  ++flushCalls;
  if (fault == 1 || fault == 7) { SetLastError(ERROR_DISK_FULL); return FALSE; }
  return FlushFileBuffers(h);
}
static BOOL TestMove(LPCWSTR from, LPCWSTR to, DWORD flags) {
  ++moveCalls;
  if (fault == 2) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
  const bool backup=wcslen(to)>=4 && wcscmp(to+wcslen(to)-4,L".bak")==0;
  if (fault == 3 && !backup) ExitProcess(73);
  if (fault == 4 && !backup) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
  if (fault == 6 && !backup) {
    if (!MoveFileExW(from,to,flags)) return FALSE;
    ExitProcess(74);
  }
  return MoveFileExW(from, to, flags);
}
static BOOL TestDelete(LPCWSTR path) {
  if(fault==7) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
  return DeleteFileW(path);
}
#define DeleteFileW TestDelete
#define FlushFileBuffers TestFlush
#define CryptProtectData TestProtect
#define MoveFileExW TestMove
#define SHGetFolderPathW TestFolder
#define GetModuleFileNameW TestModule
#include "../CPP/7zip/UI/FileManager/PasswordVault.cpp"
#undef FlushFileBuffers
#undef DeleteFileW
#undef CryptProtectData
#undef MoveFileExW
#undef SHGetFolderPathW
#undef GetModuleFileNameW
void NPasswordVault::CInfo::Load() {
  VaultPath=us2fs(configuredPath); UseMasterPassword = useMasterSetting; RememberMasterPassword = rememberMaster;
  AutoLockMaster = true; CloseAfterFill = AutoTypeByName = PromptToSaveNew = true;
  ShowPasswordInList = ShowPasswordForUnnamed = false;
}
void NPasswordVault::CInfo::Save() const {}
void NPasswordVault::CInfo::SaveVaultPath(const FString &) {}
INT_PTR NWindows::NControl::CModalDialog::Create(LPCWSTR, HWND) {
  if (scriptedMaster) {
    static_cast<CPasswordMasterDialog *>(this)->Password = UString(scriptedMaster);
    return IDOK;
  }
  return IDCANCEL;
}
bool NWindows::NControl::CDialog::OnMessage(UINT, WPARAM, LPARAM) { return false; }
bool NWindows::NControl::CDialog::OnCommand(unsigned, unsigned, LPARAM) { return false; }
bool NWindows::NControl::CDialog::OnButtonClicked(unsigned, HWND) { return false; }
static void Require(bool ok, const char *name) {
  if (!ok) { fprintf(stderr,"FAIL: %s (Win32=%lu)\n",name,GetLastError()); ExitProcess(1); }
}
static void Add(CPasswordVault &v, const wchar_t *name) {
  CPasswordVaultEntry e; e.Name=UString(name); e.Password=UString(L"test-secret"); v.Entries().Add(e);
}
static std::vector<Byte> Bytes(const UString &path) {
  CInFile f; UInt64 size=0; Require(f.Open(path) && f.GetLength(size),"read bytes");
  std::vector<Byte> b((size_t)size); Require(ReadBuf(f,b.data(),b.size()),"read full bytes"); return b;
}
static void Put(const UString &path, const std::vector<Byte> &b) {
  COutFile f; Require(f.Create_ALWAYS(path) && WriteBuf(f,b.data(),b.size()),"write fixture");
}
static void ReportWorkerFailure(const UString &path, unsigned id, unsigned iteration,
    const wchar_t *stage, const UString &error) {
  const DWORD win32=GetLastError();
  UString reportPath=path+L".worker";reportPath.Add_UInt32(id);reportPath+=L".error.txt";
  wchar_t prefix[256];swprintf(prefix,256,L"id=%u iteration=%u stage=%ls Win32=%lu\r\n",id,iteration,stage,win32);
  std::wstring text=prefix;text+=error.Ptr();
  HANDLE f=CreateFileW(reportPath,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
  if(f!=INVALID_HANDLE_VALUE){DWORD written=0;WriteFile(f,text.data(),(DWORD)(text.size()*sizeof(wchar_t)),&written,NULL);CloseHandle(f);}
}
static PROCESS_INFORMATION Spawn(const wchar_t *mode, const UString &path, unsigned id=0) {
  wchar_t exe[32768]; GetModuleFileNameW(NULL,exe,32768);
  std::wstring cmd=L"\""; cmd+=exe; cmd+=L"\" "; cmd+=mode; cmd+=L" \""; cmd+=path.Ptr(); cmd+=L"\" "; cmd+=std::to_wstring(id);
  STARTUPINFOW si={}; si.cb=sizeof(si); PROCESS_INFORMATION pi={};
  Require(CreateProcessW(NULL,&cmd[0],NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&si,&pi),"spawn child"); return pi;
}
static DWORD Wait(PROCESS_INFORMATION &pi) {
  Require(WaitForSingleObject(pi.hProcess,120000)==WAIT_OBJECT_0,"child completion");
  DWORD code=1; GetExitCodeProcess(pi.hProcess,&code); CloseHandle(pi.hThread); CloseHandle(pi.hProcess); return code;
}
static void RestoreTests(const UString &path) {
  UString error;
  useMasterSetting=false; rememberMaster=true;
  const UString backup=path+L".bak";
  {
    CPasswordVaultRestore none;
    Require(!none.Prepare(path,NULL,error) && none.Stage==L"backup-missing","restore rejects missing backup");
  }
  {
    CPasswordVault seed; seed.SetPath(path);
    Require(seed.Load(NULL,error),"restore seed load"); Add(seed,L"first");
    Require(seed.Save(error),"restore seed generation 1"); Add(seed,L"second");
    Require(seed.Save(error),"restore seed generation 2");
  }
  const auto old=Bytes(backup), current=Bytes(path);
  {
    CPasswordVault snapshot; snapshot.SetPath(backup);
    Require(snapshot.Load(NULL,error,true),"read-only import/restore snapshot authenticates");
    Add(snapshot,L"must-not-save");
    Require(!snapshot.Save(error) && Bytes(backup)==old,"read-only snapshot cannot write or bypass session coordination");
    Require(!VaultFileExists(backup+L".session.lock"),"read-only snapshot creates no sidecar on source media");
  }
  {
    CPasswordVault live; live.SetPath(path); Require(live.Load(NULL,error),"restore active session");
    CPasswordVaultRestore r;
    Require(r.Prepare(path,NULL,error),"restore prepares despite active window");
    Require(!r.Commit(error) && r.Stage==L"vault-in-use-close-password-windows" &&
        Bytes(path)==current && Bytes(backup)==old && live.Entries().Size()==2,
        "restore refuses stale session without changing data");
  }
  {
    auto child=Spawn(L"restore-lease",path);
    UString ready=path+L".ready";
    for(unsigned i=0;i<100 && !VaultFileExists(ready);i++) Sleep(50);
    Require(VaultFileExists(ready),"child acquired shared vault session");
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"cross-process restore prepare");
    Require(!r.Commit(error) && Bytes(path)==current,"other process blocks restore");
    Require(TerminateProcess(child.hProcess,74)!=0 && Wait(child)==74,"terminate only owned lease-test child");
    Require(DeleteFileW(ready)!=0,"remove owned ready signal");
  }
  {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"prepare after crashed session releases lease");
    Put(backup,current);
    Require(!r.Commit(error) && Bytes(path)==current && Bytes(backup)==current,"changed backup aborts restore");
    Put(backup,old);
  }
  {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"prepare target conflict");
    Put(path,old);
    Require(!r.Commit(error) && Bytes(path)==old,"changed primary aborts restore");
    Put(path,current);
  }
  for(int f: {1,2,7}) {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"prepare restore fault");
    CPasswordVault::SetCachedMasterPassword(L"clear-me"); fault=f;
    const bool ok=r.Commit(error); fault=0;
    Require(!ok && Bytes(path)==current && Bytes(backup)==old && !CPasswordVault::HaveCachedMasterPassword(),
        "restore flush/replace failure preserves bytes and clears cache");
    Require(r.SystemError==(f==2?ERROR_ACCESS_DENIED:ERROR_DISK_FULL),"restore preserves the original failing API error code");
    if(f==7) {
      Require(!r.CleanupWarning.IsEmpty() && r.CleanupWarning.Find(r.SafetyCopyPath)>=0 &&
          GetFileAttributesW(r.SafetyCopyPath)!=INVALID_FILE_ATTRIBUTES,
          "cleanup failure reports retained ciphertext separately from restore failure");
      Require(DeleteFileW(r.SafetyCopyPath)!=0,"remove own injected cleanup fixture");
    } else Require(r.CleanupWarning.IsEmpty(),"successful cleanup has no warning");
    if(f==2) Require(Bytes(r.SafetyCopyPath)==current,"failed replacement retains verified safety copy");
  }
  {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"prepare restore real ACL denial");
    PSECURITY_DESCRIPTOR fileAcl=NULL,dirAcl=NULL;
    const UString parent=path.Left((unsigned)path.ReverseFind_PathSepar());
    Require(DenyCurrentUserAccess(path,DELETE,fileAcl),"deny restore delete primary");
    if(!DenyCurrentUserAccess(parent,FILE_DELETE_CHILD,dirAcl)) {
      RestoreDacl(path,fileAcl); Require(false,"deny restore parent delete child");
    }
    const bool ok=r.Commit(error);
    const bool restoredFile=RestoreDacl(path,fileAcl),restoredDir=RestoreDacl(parent,dirAcl);
    Require(restoredFile && restoredDir,"restore fixture ACLs");
    Require(!ok && r.Stage==L"replace-primary" && Bytes(path)==current && Bytes(backup)==old,
        "real ACL denial refuses recovery without modifying main or backup");
  }
  {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"prepare successful restore");
    CPasswordVault unrelated; unrelated.SetPath(path+L".unrelated");
    Require(unrelated.Load(NULL,error),"unrelated vault has its own session");
    Require(r.EntryCount()==1 && !r.MasterMode() && r.Commit(error) && r.Committed,
        "restore commits authenticated previous generation");
    Require(Bytes(path)==old && Bytes(backup)==old && Bytes(r.SafetyCopyPath)==current,
        "restore exact bytes and safety copy; source backup unchanged");
    Require(!r.Commit(error),"restore proposal is single use");
  }
  {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error) && r.AlreadyCurrent(),"identical restore is detected");
    Require(r.Commit(error) && !r.Committed && r.SafetyCopyPath.IsEmpty(),"identical restore writes no copies");
  }
  for(int scenario=0;scenario<2;scenario++) {
    if(scenario==0) Require(DeleteFileW(path)!=0,"remove primary for missing-primary restore");
    else Put(path,{1,2,3});
    CPasswordVaultRestore r;
    Require(r.Prepare(path,NULL,error) && r.Commit(error) && Bytes(path)==old && Bytes(backup)==old,
        "restore works with missing or damaged primary");
    if(scenario==1) Require(Bytes(r.SafetyCopyPath)==std::vector<Byte>({1,2,3}),"damaged primary preserved exactly");
  }
  for(int scenario=0;scenario<4;scenario++) {
    auto damaged=old;
    if(scenario==0) damaged.clear();
    if(scenario==1) damaged[4]=3;
    if(scenario==2) damaged.resize(7);
    if(scenario==3) damaged.back()^=0x80;
    Put(backup,damaged);
    CPasswordVaultRestore r;
    Require(!r.Prepare(path,NULL,error) && !r.Commit(error) && Bytes(path)==old && Bytes(backup)==damaged,
        "restore rejects empty, legacy, truncated or tampered backup");
  }
  Put(backup,old);
  for(int crash: {3,6}) {
    Put(path,current);
    auto child=Spawn(crash==3?L"restore-crash-before":L"restore-crash-after",path);
    Require(Wait(child)==(crash==3?73:74),"restore child stopped at requested commit boundary");
    Require(Bytes(path)==(crash==3?current:old) && Bytes(backup)==old,
        "restore process crash leaves a complete generation and intact backup");
    if(crash==3) {
      const UString material=PasswordVault_FindRestoreMaterial(path);
      Require(!material.IsEmpty() && Bytes(material)==old,"interrupted restore ciphertext is discoverable without consuming it");
      Require(PasswordVault_FindRestoreMaterial(path+L".different").IsEmpty(),"recovery notice does not match another vault");
    }
    WIN32_FIND_DATAW found;
    HANDLE search=FindFirstFileW(path+L".pre-restore-*",&found);
    Require(search!=INVALID_HANDLE_VALUE,"restore crash leaves encrypted safety copy");
    bool valid=false;
    do {
      UString saved=path.Left((unsigned)path.ReverseFind_PathSepar()+1); saved+=found.cFileName;
      if(Bytes(saved)==current) valid=true;
    } while(FindNextFileW(search,&found));
    FindClose(search);
    Require(valid,"crash safety copy contains complete original ciphertext");
  }
  Require(DeleteFileW(backup)!=0 && CreateDirectoryW(backup,NULL)!=0,"restore backup-directory fixture");
  { CPasswordVaultRestore r; Require(!r.Prepare(path,NULL,error),"restore rejects backup directory"); }
  Require(RemoveDirectoryW(backup)!=0 && CreateTestSymlink(backup,path),"restore backup-symlink fixture");
  { CPasswordVaultRestore r; Require(!r.Prepare(path,NULL,error),"restore rejects backup symlink"); }
  Require(DeleteFileW(backup)!=0 && CreateHardLinkW(backup,path,NULL)!=0,"restore hardlink fixture");
  { CPasswordVaultRestore r; Require(!r.Prepare(path,NULL,error),"restore rejects hardlink aliases"); }
  Require(DeleteFileW(backup)!=0,"remove owned backup link"); Put(backup,old);
  {
    CPasswordVault v; v.SetPath(path); Require(v.Load(NULL,error),"reload restored library");
    Add(v,L"after-restore"); Require(v.Save(error) && Bytes(backup)==old,"normal save after restore rotates backup");
    CPasswordVault::SetCachedMasterPassword(L"old-backup-master");
    Require(v.Save(error,NULL,1),"create master generation");
    CPasswordVault::SetCachedMasterPassword(L"new-current-master");
    Require(v.Save(error,NULL,1),"change master and retain old master backup");
  }
  const auto masterCurrent=Bytes(path),masterBackup=Bytes(backup);
  for(const wchar_t *password: { (const wchar_t *)NULL, L"wrong", L"old-backup-master" }) {
    scriptedMaster=password;
    CPasswordVault::SetCachedMasterPassword(L"new-current-master");
    CPasswordVaultRestore r;
    const bool prepared=r.Prepare(path,NULL,error);
    Require(!CPasswordVault::HaveCachedMasterPassword(),"restore always clears master cache");
    if(!password || wcscmp(password,L"wrong")==0)
      Require(!prepared && Bytes(path)==masterCurrent && Bytes(backup)==masterBackup,"cancel or wrong backup password leaves files intact");
    else Require(prepared && r.MasterMode() && r.Commit(error) && Bytes(path)==masterBackup,
        "old backup password restores after master password change");
  }
  scriptedMaster=NULL; useMasterSetting=false;
  puts("PASS: authenticated restore, safety copies, conflicts, shared sessions/crash release, real ACL, faults, formats, paths, and old master password");
}
int wmain(int argc, wchar_t **argv) {
  if(argc<3) return 2;
  const UString path(argv[2]); UString error;
  if(wcscmp(argv[1],L"suite")==0 || wcscmp(argv[1],L"languages")==0) {
    for(const char *id: {"en","zh-cn","zh-tw"}) {
      UString name=L"Lang\\";
      for(const char *c=id;*c;c++) name+=(wchar_t)*c;
      name+=L".txt";
      CLang lang;
      fprintf(stderr,"LANGUAGE: %s\n",id);
      Require(lang.Open(name,"7-Zip"),"production language parser accepts complete resource");
      Require(lang.Get(2617)!=NULL,"restore button translation exists");
      for(unsigned n=3880;n<=3889;n++) Require(lang.Get(n)!=NULL,"restore message translation exists");
      for(const wchar_t *marker: {L"{0}",L"{1}",L"{2}",L"{3}",L"{4}"})
        Require(wcsstr(lang.Get(3882),marker)!=NULL,"restore confirmation retains every substitution");
    }
    puts("PASS: production language parser validates en, zh-cn, zh-tw and restore messages");
    if(wcscmp(argv[1],L"languages")==0) return 0;
  }
  if(wcscmp(argv[1],L"cross-account-seed")==0) {
    CPasswordVault v; v.SetPath(path); Require(v.Load(NULL,error),"cross-account seed load");
    Add(v,L"cross-account-generation-one"); Require(v.Save(error),"cross-account first encrypted generation");
    Add(v,L"cross-account-generation-two"); Require(v.Save(error),"cross-account second encrypted generation");
    puts("PASS: real DPAPI backup fixture created for this Windows account"); return 0;
  }
  if(wcscmp(argv[1],L"cross-account-reject")==0) {
    const auto primary=Bytes(path), backup=Bytes(path+L".bak");
    CPasswordVaultRestore r; CPasswordVault::SetCachedMasterPassword(L"clear-me");
    Require(!r.Prepare(path,NULL,error) && r.Stage==L"authenticate-backup" && !error.IsEmpty(),
        "different Windows account cannot authenticate the DPAPI backup");
    Require(Bytes(path)==primary && Bytes(path+L".bak")==backup && !r.Committed &&
        !CPasswordVault::HaveCachedMasterPassword(),"wrong-account refusal leaves files unchanged and clears cache");
    puts("PASS: real cross-account DPAPI restore refusal and unchanged encrypted files"); return 0;
  }
  if(wcscmp(argv[1],L"restore-lease")==0) {
    CPasswordVault v; v.SetPath(path); Require(v.Load(NULL,error),"child holds vault lease");
    Put(path+L".ready",{}); Sleep(120000); return 0;
  }
  if(wcscmp(argv[1],L"restore-crash-before")==0 || wcscmp(argv[1],L"restore-crash-after")==0) {
    CPasswordVaultRestore r; Require(r.Prepare(path,NULL,error),"crash restore prepare");
    fault=wcscmp(argv[1],L"restore-crash-before")==0?3:6;
    r.Commit(error); return 2;
  }
  if(wcscmp(argv[1],L"acl")==0) {
    // This isolated mode exercises the production save/backup path with a real
    // Windows DACL while avoiding DPAPI, whose master keys may be unavailable
    // in restricted test accounts. AES/CNG and the real file system remain in use.
    useMasterSetting=true;
    CPasswordVault vault; vault.SetPath(path);
    Require(vault.Load(NULL,error),"load missing ACL fixture");
    CPasswordVault::SetCachedMasterPassword(L"acl-test-master"); Add(vault,L"before-acl");
    Require(vault.Save(error),"create encrypted ACL fixture");
    CPasswordVault::ClearCachedMasterPassword();
    const std::vector<Byte> original=Bytes(path);
    const UString backupPath=path+L".bak";
    CPasswordVault::SetCachedMasterPassword(L"acl-test-master"); Add(vault,L"denied-update");
    const UString parentPath=path.Left((unsigned)path.ReverseFind(L'\\'));
    PSECURITY_DESCRIPTOR originalDirectory=NULL,originalVault=NULL;
    const bool denyParent=DenyCurrentUserAccess(parentPath,FILE_DELETE_CHILD,originalDirectory);
    const bool denyVault=denyParent && DenyCurrentUserAccess(path,DELETE,originalVault);
    if(!denyVault) {
      const DWORD aclError=GetLastError();
      if(originalVault) RestoreDacl(path,originalVault);
      if(originalDirectory) RestoreDacl(parentPath,originalDirectory);
      fprintf(stderr,"ENVIRONMENT_BLOCKED: cannot apply fixture-only DACL denial (error=%lu); real ACL save test NOT PASSED.\n",aclError);
      return 78;
    }
    const bool saved=vault.Save(error);
    const bool vaultRestored=RestoreDacl(path,originalVault);
    const bool directoryRestored=RestoreDacl(parentPath,originalDirectory);
    const bool backupPublished=VaultFileExists(backupPath);
    fprintf(stderr,"REAL-ACL: deny DELETE on primary + FILE_DELETE_CHILD on parent; save=%s; backupPublished=%s; restore=%s\n",
        saved?"unexpectedly-succeeded":"denied",backupPublished?"yes":"no",
        vaultRestored&&directoryRestored?"OK":"FAILED");
    Require(vaultRestored && directoryRestored,"restore exact fixture DACLs after real ACL denial");
    Require(!saved && Bytes(path)==original && Bytes(backupPath)==original && vault.Entries().Size()==1 &&
        !CPasswordVault::HaveCachedMasterPassword(),
        "real ACL replacement denial preserves primary and backup, rolls back memory and clears cache");
    puts("PASS: real Windows ACL denial at primary replacement; encrypted bytes, backup, memory and cache invariants preserved");
    return 0;
  }
  if(wcscmp(argv[1],L"fault-disk")==0) {
    // A deterministic API-boundary fault test. It is explicitly reported as
    // injected, never as a real full-volume test.
    useMasterSetting=true;
    CPasswordVault vault; vault.SetPath(path);
    Require(vault.Load(NULL,error),"load missing disk-fault fixture");
    CPasswordVault::SetCachedMasterPassword(L"disk-fault-test-master"); Add(vault,L"before-disk-fault");
    Require(vault.Save(error),"create encrypted disk-fault fixture");
    const std::vector<Byte> original=Bytes(path);
    const UString backupPath=path+L".bak";
    CPasswordVault::SetCachedMasterPassword(L"disk-fault-test-master"); Add(vault,L"disk-full-update");
    fault=1; const bool saved=vault.Save(error); fault=0;
    fprintf(stderr,"DISK-FAULT: injected ERROR_DISK_FULL at FlushFileBuffers; save=%s; flushCalls=%u\n",
        saved?"unexpectedly-succeeded":"failed",flushCalls);
    Require(!saved && Bytes(path)==original && !VaultFileExists(backupPath) && vault.Entries().Size()==1 &&
        !CPasswordVault::HaveCachedMasterPassword(),
        "injected disk-full failure preserves primary and backup, rolls back memory and clears cache");
    puts("PASS: injected ERROR_DISK_FULL failure invariants; this is not a real full-volume test");
    return 0;
  }
  if(wcscmp(argv[1],L"disk-seed")==0) {
    useMasterSetting=true;
    CPasswordVault vault; vault.SetPath(path);
    CPasswordVault::SetCachedMasterPassword(L"real-disk-test-master");
    Require(vault.Load(NULL,error),"load missing real-disk fixture");
    // Force the encrypted seed and subsequent temporary/backup images outside
    // NTFS's resident $DATA storage. Otherwise a tiny vault may still save via
    // free MFT record space after AvailableFreeSpace reaches zero, which is a
    // valid filesystem behavior rather than a failed full-disk save.
    CPasswordVaultEntry seed;
    seed.Name=UString(L"before-full-volume");
    std::wstring clusterBackedData(256*1024,L'X');
    seed.Password=UString(clusterBackedData.c_str());
    vault.Entries().Add(seed);
    Require(vault.Save(error) && VaultFileExists(path) && !VaultFileExists(path+L".bak"),
        "seed encrypted vault before filling isolated volume");
    CPasswordVault::ClearCachedMasterPassword();
    puts("PASS: encrypted master-password fixture seeded on the test volume");
    {
      CPasswordVault recovery; recovery.SetPath(path+L".restore");
      Require(recovery.Load(NULL,error),"restore full-volume seed load");
      recovery.Entries().Add(seed);
      CPasswordVault::SetCachedMasterPassword(L"real-disk-test-master");
      Require(recovery.Save(error),"restore full-volume generation 1");
      Add(recovery,L"second-generation");
      CPasswordVault::SetCachedMasterPassword(L"real-disk-test-master");
      Require(recovery.Save(error),"restore full-volume generation 2");
    }
    {
      scriptedMaster=L"real-disk-test-master";
      CPasswordVaultRestore r;
      Require(r.Prepare(path+L".restore",NULL,error),"restore full-volume preflight and lock files");
      scriptedMaster=NULL;
    }
    return 0;
  }
  if(wcscmp(argv[1],L"disk-full-restore")==0) {
    const auto before=Bytes(path),backup=Bytes(path+L".bak");
    scriptedMaster=L"real-disk-test-master";
    CPasswordVaultRestore r;
    Require(r.Prepare(path,NULL,error),"authenticate restore backup on full volume");
    const bool ok=r.Commit(error);
    fwprintf(stderr,L"REAL-DISK-RESTORE: committed=%ls stage=%ls Win32=%lu\n",
        ok?L"yes":L"no",r.Stage.Ptr(),r.SystemError);
    Require(!ok && (r.SystemError==ERROR_DISK_FULL || r.SystemError==ERROR_HANDLE_DISK_FULL) &&
        Bytes(path)==before && Bytes(path+L".bak")==backup && !CPasswordVault::HaveCachedMasterPassword(),
        "real full-volume restore preserves primary, backup and clears cache");
    puts("PASS: restore transaction refused on genuinely full volume");
    return 0;
  }
  if(wcscmp(argv[1],L"disk-full")==0) {
    useMasterSetting=true;
    CPasswordVault vault; vault.SetPath(path);
    CPasswordVault::SetCachedMasterPassword(L"real-disk-test-master");
    Require(vault.Load(NULL,error),"load encrypted vault on full test volume");
    const std::vector<Byte> original=Bytes(path);
    const UString backupPath=path+L".bak";
    const bool hadBackup=VaultFileExists(backupPath);
    const std::vector<Byte> originalBackup=hadBackup ? Bytes(backupPath) : std::vector<Byte>();
    const unsigned originalCount=vault.Entries().Size();
    Add(vault,L"must-not-commit-on-full-volume");
    CPasswordVault::SetCachedMasterPassword(L"real-disk-test-master");
    const bool saved=vault.Save(error);
    const DWORD saveError=saved ? 0 : GetLastError();
    const bool primaryUnchanged=Bytes(path)==original;
    const bool backupUnchanged=hadBackup ? (VaultFileExists(backupPath) && Bytes(backupPath)==originalBackup)
        : !VaultFileExists(backupPath);
    if(saved)
      fwprintf(stderr,L"REAL-DISK-FULL: save=unexpectedly-succeeded; last-error=undefined-on-success; primaryUnchanged=%ls; backupUnchanged=%ls; entries=%u; cache=%ls\n",
          primaryUnchanged?L"yes":L"no",backupUnchanged?L"yes":L"no",vault.Entries().Size(),
          CPasswordVault::HaveCachedMasterPassword()?L"present":L"cleared");
    else
      fwprintf(stderr,L"REAL-DISK-FULL: save=failed Win32=%lu; %ls\n",saveError,error.Ptr());
    Require(!saved && primaryUnchanged && backupUnchanged && vault.Entries().Size()==originalCount &&
        !CPasswordVault::HaveCachedMasterPassword(),
        "real full-volume failure preserves primary and backup, rolls back memory and clears cache");
    puts("PASS: real full-volume save failure preserved encrypted state and rolled back memory/cache");
    return 0;
  }
  if(wcscmp(argv[1],L"writer")==0) {
    unsigned id=(unsigned)_wtoi(argv[3]);
    for(unsigned i=0;i<100;i++) {
      CPasswordVault v; v.SetPath(path);
      if(!v.Load(NULL,error)) {
        ReportWorkerFailure(path,id,i,L"Load",error);
        fwprintf(stderr,L"WORKER %u iteration %u LOAD FAILED: %ls (Win32=%lu)\n",id,i,error.Ptr(),GetLastError());
        return 11;
      }
      UString name=L"writer-"; name.Add_UInt32(id); name+=L"-"; name.Add_UInt32(i); Add(v,name);
      Sleep(2);
      if(!v.Save(error)) {
        ReportWorkerFailure(path,id,i,L"Save",error);
        fwprintf(stderr,L"WORKER %u iteration %u SAVE FAILED: %ls (Win32=%lu)\n",id,i,error.Ptr(),GetLastError());
        return 12;
      }
    }
    return 0;
  }
  if(wcscmp(argv[1],L"crash")==0) {
    CPasswordVault v; v.SetPath(path); Require(v.Load(NULL,error),"crash load"); Add(v,L"never-committed"); fault=3; v.Save(error); return 2;
  }
  fixtureRoot=path+L".paths";
  Require(CreateDirectoryW(fixtureRoot,NULL)!=0,"create path fixture");
  Require(CreateDirectoryW(fixtureRoot+L"\\portable",NULL)!=0,"create portable fixture");
  Require(CreateDirectoryW(fixtureRoot+L"\\appdata",NULL)!=0,"create appdata fixture");
  Require(CreateDirectoryW(fixtureRoot+L"\\appdata\\7-Zip",NULL)!=0,"create roaming fixture");
  UString portable,roaming; Require(GetDefaultPair(portable,roaming),"default pair");
  UString p,r;
  Require(!CPasswordVault::GetTwoDefaults(p,r) && CPasswordVault::GetDefaultPath()==roaming,"no files uses APPDATA without chooser");
  Put(portable,{});
  Require(!CPasswordVault::GetTwoDefaults(p,r) && CPasswordVault::GetDefaultPath()==portable,"portable only uses existing vault");
  Put(roaming,{});
  Require(CPasswordVault::GetTwoDefaults(p,r),"both files require choice");
  configuredPath=path;
  Require(!CPasswordVault::GetTwoDefaults(p,r) && CPasswordVault::GetConfiguredPath()==path,"explicit path suppresses chooser");
  configuredPath.Empty(); Require(DeleteFileW(portable)!=0,"remove owned portable fixture");
  Require(!CPasswordVault::GetTwoDefaults(p,r) && CPasswordVault::GetDefaultPath()==roaming,"roaming only uses existing vault");
  Require(CreateDirectoryW(portable,NULL)!=0,"directory named as vault");
  Require(!CPasswordVault::GetTwoDefaults(p,r),"directory is not a second vault");
  CPasswordVault a,b; a.SetPath(path); b.SetPath(path);
  Require(a.Load(NULL,error) && b.Load(NULL,error),"empty vault");
  const UString backupPath=path+L".bak";
  // Independent real-API probe. Never substitutes fake crypto or skips the suite.
  BYTE probeByte=42; DATA_BLOB probeIn={1,&probeByte},probeOut={};
  const BOOL probeOK=CryptProtectData(&probeIn,L"native test environment probe",NULL,NULL,NULL,0,&probeOut);
  const DWORD probeError=probeOK ? 0 : GetLastError();
  if(probeOK) LocalFree(probeOut.pbData);
  fprintf(stderr,"ENVIRONMENT: independent CryptProtectData=%s error=%lu\n",probeOK?"OK":"FAILED",probeError);
  Add(a,L"A"); Add(b,L"B");
  CPasswordVault::SetCachedMasterPassword(L"failure-cache-probe");
  if(!a.Save(error)) {
    fprintf(stderr,"FAIL: first save; protectError=%lu flushCalls=%u moveCalls=%u\n",protectError,flushCalls,moveCalls);
    fwprintf(stderr,L"Production error: %ls\n",error.Ptr());
    Require(!VaultFileExists(path) && !VaultFileExists(backupPath) && a.Entries().IsEmpty() &&
        !CPasswordVault::HaveCachedMasterPassword(),"first failure preserves disk/backup, rolls back memory, clears cache");
    if(!probeOK && protectError==probeError) {
      fputs("ENVIRONMENT_BLOCKED: real DPAPI probe and production encryption both failed before flush/readback/backup/replace; suite NOT PASSED.\n",stderr);
      return 78;
    }
    return 1;
  }
  CPasswordVault::ClearCachedMasterPassword();
  Require(!VaultFileExists(backupPath),"first save has no previous generation");
  const auto initial=Bytes(path); Require(b.Save(error),"merge second generation");
  Require(Bytes(backupPath)==initial,"backup is exact previous ciphertext");
  const UString alias=path+L".link";
  if(!CreateTestSymlink(alias,path)) {
    fprintf(stderr,"ENVIRONMENT_BLOCKED: cannot create file symlink fixture (error=%lu); suite NOT PASSED.\n",GetLastError());
    return 78;
  }
  CPasswordVault linkVault; linkVault.SetPath(alias);
  Require(!linkVault.Load(NULL,error) && !linkVault.Save(error),"vault symlink rejected");
  Require(Bytes(path)!=initial && Bytes(backupPath)==initial,"symlink rejection preserves target and backup");
  Require(DeleteFileW(alias)!=0,"remove owned symlink");
  const UString directoryVault=path+L".directory";
  // Resolve a file path first, then replace its leaf with a directory. SetPath
  // intentionally accepts user-selected folders and appends the default name.
  linkVault.SetPath(directoryVault);
  Require(CreateDirectoryW(directoryVault,NULL)!=0,"directory vault fixture");
  Require(!linkVault.Load(NULL,error) && !linkVault.Save(error),"directory vault rejected");
  const UString other=path+L".other";
  Require(HashVaultPath(path)!=HashVaultPath(other),"distinct leaves have distinct mutex keys");
  Require(HashVaultPath(path)==HashVaultPath(fixtureRoot+L"\\..\\fixture.dat"),"equivalent path shares mutex key");
  linkVault.SetPath(other); Require(linkVault.Load(NULL,error),"missing leaf with existing parent loads");
  Add(linkVault,L"other"); Require(linkVault.Save(error),"missing leaf with existing parent saves");
  const auto otherBytes=Bytes(other);
  const UString otherBackup=other+L".bak";
  Require(CreateDirectoryW(otherBackup,NULL)!=0,"backup directory fixture");
  Add(linkVault,L"rejected"); CPasswordVault::SetCachedMasterPassword(L"clear-on-path-failure");
  Require(!linkVault.Save(error) && Bytes(other)==otherBytes && linkVault.Entries().Size()==1 &&
      !CPasswordVault::HaveCachedMasterPassword(),"backup directory fails with rollback and cache clear");
  Require(RemoveDirectoryW(otherBackup)!=0,"remove owned empty backup directory");
  Require(CreateTestSymlink(otherBackup,backupPath),"backup symlink fixture");
  Add(linkVault,L"rejected-link");
  Require(!linkVault.Save(error) && Bytes(other)==otherBytes && Bytes(backupPath)==initial,"backup symlink fails without overwriting its target");
  Require(DeleteFileW(otherBackup)!=0,"remove owned backup link");
  Require(a.Load(NULL,error) && a.Entries().Size()==2,"both records retained");
  auto good=Bytes(path); Require(good[4]==4 && good[5]==0,"DPAPI v4 format");
  for(int f : {1,2,5}) {
    CPasswordVault::SetCachedMasterPassword(L"must-be-cleared");
    Add(a,L"failed"); fault=f; Require(!a.Save(error),"injected save failure"); fault=0;
    Require(!CPasswordVault::HaveCachedMasterPassword() && Bytes(backupPath)==initial,"failure clears cache and preserves backup");
    Require(a.Entries().Size()==2 && Bytes(path)==good,"failed save rolls memory and disk back");
  }
  HANDLE backupDeny=CreateFileW(backupPath,GENERIC_READ,0,NULL,OPEN_EXISTING,0,NULL);
  Require(backupDeny!=INVALID_HANDLE_VALUE,"lock backup"); Add(a,L"backup-locked");
  Require(!a.Save(error) && Bytes(path)==good,"backup failure aborts primary replacement"); CloseHandle(backupDeny);
  Add(a,L"primary-failure"); fault=4; Require(!a.Save(error),"primary replacement failure"); fault=0;
  Require(Bytes(path)==good && Bytes(backupPath)==good,"failed primary leaves original recoverable");
  // Exercise a real Windows DACL denial against only this disposable fixture.
  // Removing the prior backup makes backup publication create-only; the deny
  // then blocks replacement of the existing primary, after which both exact
  // DACLs are restored before the fixture continues.
  Require(DeleteFileW(backupPath)!=0,"prepare ACL replacement fixture");
  PSECURITY_DESCRIPTOR originalDirectory=NULL,originalVault=NULL;
  const UString parentPath=path.Left(path.ReverseFind(L'\\'));
  const bool denyParent=DenyCurrentUserAccess(parentPath,FILE_DELETE_CHILD,originalDirectory);
  const bool denyVault=denyParent && DenyCurrentUserAccess(path,DELETE,originalVault);
  if(!denyVault) {
    const DWORD aclError=GetLastError();
    if(originalVault) RestoreDacl(path,originalVault);
    if(originalDirectory) RestoreDacl(parentPath,originalDirectory);
    fprintf(stderr,"ENVIRONMENT_BLOCKED: cannot apply fixture-only DACL denial (error=%lu); real ACL save test NOT PASSED.\n",aclError);
    return 78;
  }
  CPasswordVault::SetCachedMasterPassword(L"real-acl-failure-cache"); Add(a,L"real-acl-failure");
  const bool aclSaved=a.Save(error);
  const bool vaultRestored=RestoreDacl(path,originalVault);
  const bool directoryRestored=RestoreDacl(parentPath,originalDirectory);
  fprintf(stderr,"REAL-ACL: deny DELETE on primary + FILE_DELETE_CHILD on parent; save=%s; restore=%s\n",
      aclSaved?"unexpectedly-succeeded":"denied",vaultRestored&&directoryRestored?"OK":"FAILED");
  Require(vaultRestored && directoryRestored,"restore exact fixture DACLs after real ACL denial");
  Require(!aclSaved && Bytes(path)==good && Bytes(backupPath)==good && a.Entries().Size()==2 &&
      !CPasswordVault::HaveCachedMasterPassword(),
      "real ACL replacement denial preserves primary and backup, rolls back memory and clears cache");
  HANDLE deny=CreateFileW(path,GENERIC_READ,0,NULL,OPEN_EXISTING,0,NULL);
  Require(deny!=INVALID_HANDLE_VALUE,"exclusive handle"); Add(a,L"locked"); Require(!a.Save(error),"locked vault save rejected");
  CPasswordVault locked; locked.SetPath(path); Require(!locked.Load(NULL,error) && !locked.Save(error),"unreadable vault cannot save"); CloseHandle(deny);
  Require(Bytes(path)==good && a.Entries().Size()==2,"locked failure preserved state");
  Require(a.Load(NULL,error) && b.Load(NULL,error),"load for conflict");
  a.Entries()[0].Password=UString(L"first-change"); b.Entries()[0].Password=UString(L"second-change");
  Require(a.Save(error),"first edit"); auto first=Bytes(path);
  Require(Bytes(backupPath)==good,"backup rotates to immediately preceding generation");
  Require(!b.Save(error) && Bytes(path)==first,"same-entry conflict rejected");
  Require(a.Load(NULL,error) && b.Load(NULL,error),"load for edit/add");
  a.Entries().Delete(0); Add(b,L"independent"); Require(a.Save(error) && b.Save(error),"delete and independent add merge");
  Require(b.FindByName(L"A")<0 && b.FindByName(L"independent")>=0,"deletion not resurrected");
  good=Bytes(path); auto broken=good; broken.back()^=0x80; Put(path,broken);
  CPasswordVault bad; bad.SetPath(path); Require(!bad.Load(NULL,error) && !bad.Save(error),"tampered DPAPI rejected"); Require(Bytes(path)==broken,"tampered vault not overwritten");
  broken=good; broken.push_back(0); Put(path,broken); Require(!bad.Load(NULL,error),"trailing data rejected");
  CByteBuffer encrypted; const Byte invalid[]={2,0,0,0,0,0,0,0,0,0,0,0};
  Require(DpapiProtect(invalid,sizeof(invalid),encrypted),"malformed DPAPI fixture");
  std::vector<Byte> malformed={'7','Z','P','V',4,0}; UInt32 len=(UInt32)encrypted.Size();
  const Byte *lp=(const Byte *)&len; malformed.insert(malformed.end(),lp,lp+4);
  malformed.insert(malformed.end(),encrypted.ConstData(),encrypted.ConstData()+encrypted.Size());
  Put(path,malformed); Require(!bad.Load(NULL,error) && bad.Entries().IsEmpty(),"malformed authenticated plaintext cleared"); Put(path,good);
  Require(a.Load(NULL,error),"load for master mode");
  CPasswordVault::SetCachedMasterPassword(L"test-master-only"); Require(a.Save(error,NULL,1),"enable master"); auto masterBytes=Bytes(path);
  CPasswordVault::SetCachedMasterPassword(L"wrong-master"); Require(!bad.Load(NULL,error) && !bad.Save(error),"wrong master refused");
  Require(!CPasswordVault::HaveCachedMasterPassword(),"wrong cached master cleared");
  Require(!bad.Load(NULL,error) && Bytes(path)==masterBytes,"cancel leaves original bytes");
  CPasswordVault::SetCachedMasterPassword(L"test-master-only"); Require(bad.Load(NULL,error),"correct master unlock");
  Require(bad.Save(error,NULL,0),"switch back to DPAPI"); CPasswordVault::ClearCachedMasterPassword();
  Require(Bytes(backupPath)==masterBytes,"mode change preserves encrypted master backup");
  CPasswordVault previous; previous.SetPath(backupPath);
  CPasswordVault::SetCachedMasterPassword(L"wrong-master"); Require(!previous.Load(NULL,error),"backup rejects wrong master");
  CPasswordVault::SetCachedMasterPassword(L"test-master-only"); Require(previous.Load(NULL,error),"backup decrypts with previous master");
  CPasswordVault::ClearCachedMasterPassword();
  good=Bytes(path); Require(a.Load(NULL,error),"load before save cancellation");
  const unsigned beforeCount=a.Entries().Size(); Add(a,L"cancelled-save");
  Require(!a.Save(error,NULL,1) && Bytes(path)==good && a.Entries().Size()==beforeCount,"cancel save rolls back");
  CPasswordVault::SetCachedMasterPassword(L"expired-test-master");
  g_MasterPasswordTick=GetTickCount()-kMasterIdleMs-1;
  CVaultString expired;
  Require(!CPasswordVault::GetMasterPassword(NULL,expired,error) && !CPasswordVault::HaveCachedMasterPassword(),"expired cache prompts again");
  Require(a.Entries().Size()==beforeCount,"cache expiry does not pretend to lock the vault");
  rememberMaster=false;
  CPasswordVault::SetCachedMasterPassword(L"one-shot-master");
  Require(CPasswordVault::GetMasterPassword(NULL,expired,error) &&
      !CPasswordVault::HaveCachedMasterPassword(),"remember disabled consumes and wipes one-shot cache");
  expired.Wipe(); rememberMaster=true;
  // Equal timestamps and file size cannot hide a concurrent change.
  Require(a.Load(NULL,error) && b.Load(NULL,error),"load for same metadata");
  HANDLE attr=CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
  FILETIME oldTime; Require(attr!=INVALID_HANDLE_VALUE && GetFileTime(attr,NULL,NULL,&oldTime),"read timestamp"); CloseHandle(attr);
  b.Entries()[0].Password=UString(L"new-secret!"); Require(b.Save(error),"same-size edit");
  attr=CreateFileW(path,FILE_WRITE_ATTRIBUTES,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
  Require(attr!=INVALID_HANDLE_VALUE && SetFileTime(attr,NULL,NULL,&oldTime),"restore timestamp"); CloseHandle(attr);
  Add(a,L"same-metadata-add"); Require(a.Save(error) && a.Entries()[0].Password==UString(L"new-secret!"),"merge uses content instead of metadata");
  // Old DPAPI layouts are read, but only v4 is ever written.
  for(Byte version=2;version<=3;version++) {
    UString legacyPath=path+L".legacy"; legacyPath.Add_UInt32(version);
    CByteBuffer n,p;
    const wchar_t *name=L"legacy", *password=L"old-secret";
    Require(DpapiProtect(name,12,n) && DpapiProtect(password,20,p),"legacy encryption");
    { COutFile f; Require(f.Create_ALWAYS(legacyPath),"legacy create"); Byte mode=0;
      Require(WriteBuf(f,kMagic,4) && WriteBuf(f,&version,1) && WriteBuf(f,&mode,1) && WriteUInt32(f,1),"legacy header");
      if(version==2) Require(WriteUInt32(f,12) && WriteBuf(f,name,12),"v2 name");
      else Require(WriteUInt32(f,(UInt32)n.Size()) && WriteBuf(f,n,n.Size()),"v3 name");
      Require(WriteUInt32(f,(UInt32)p.Size()) && WriteBuf(f,p,p.Size()),"legacy password"); }
    CPasswordVault legacy;legacy.SetPath(legacyPath);
    Require(legacy.Load(NULL,error) && legacy.FindByName(L"legacy")==0 && legacy.Save(error),"legacy read and migrate");
    Require(Bytes(legacyPath)[4]==4,"legacy save upgrades to v4");
  }
  good=Bytes(path); auto crash=Spawn(L"crash",path); Require(Wait(crash)==73 && Bytes(path)==good,"crash before replace preserves original");
  auto p1=Spawn(L"writer",path,1); auto p2=Spawn(L"writer",path,2);
  const DWORD worker1=Wait(p1),worker2=Wait(p2);
  if(worker1 || worker2) fprintf(stderr,"WORKER EXIT CODES: first=%lu second=%lu\n",worker1,worker2);
  Require(worker1==0 && worker2==0,"two processes: 100 saves each");
  Require(a.Load(NULL,error),"read concurrency result");
  previous.SetPath(backupPath); Require(previous.Load(NULL,error) && previous.Entries().Size()+1==a.Entries().Size(),"concurrent backup retains preceding generation");
  for(unsigned id=1;id<=2;id++) for(unsigned i=0;i<100;i++) {
    UString name=L"writer-"; name.Add_UInt32(id); name+=L"-"; name.Add_UInt32(i); Require(a.FindByName(name)>=0,"all concurrent records present");
  }
  RestoreTests(path+L".restore");
  puts("PASS: default paths, encrypted backup rotation/recovery/failures, cache clearing, real DPAPI/AES, cancellation, corruption, rollback, locked files, crash recovery, and 200 concurrent saves");
  return 0;
}

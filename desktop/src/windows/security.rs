//! User-only ACLs for speech files and the local command pipe.
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr::null_mut;

use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    SE_FILE_OBJECT, SetNamedSecurityInfoW,
};
use windows_sys::Win32::Security::{
    DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl, GetTokenInformation,
    PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
    TOKEN_USER, TokenUser,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

pub fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
    value.encode_wide().chain(Some(0)).collect()
}

pub fn user_sid() -> io::Result<String> {
    unsafe {
        let mut raw = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw) == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = OwnedHandle::from_raw_handle(raw);
        let mut size = 0;
        GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut size);
        if size == 0 {
            return Err(io::Error::last_os_error());
        }
        // usize storage provides the alignment TOKEN_USER requires.
        let mut data = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
        if GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            data.as_mut_ptr().cast(),
            size,
            &mut size,
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let user = &*data.as_ptr().cast::<TOKEN_USER>();
        let mut sid = null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut len = 0;
        while *sid.add(len) != 0 {
            len += 1;
        }
        let result = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
        LocalFree(sid.cast());
        Ok(result)
    }
}

pub struct Descriptor(PSECURITY_DESCRIPTOR);

impl Descriptor {
    pub fn current_user() -> io::Result<Self> {
        // Protected DACL: only this user and SYSTEM; OI/CI propagates to files.
        let sddl = format!("D:P(A;OICI;GA;;;{})(A;OICI;GA;;;SY)", user_sid()?);
        let sddl = wide(std::ffi::OsStr::new(&sddl));
        let mut descriptor = null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(descriptor))
    }

    pub fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.0,
            bInheritHandle: 0,
        }
    }
}

impl Drop for Descriptor {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}

pub fn private_dir(path: &Path) -> Result<(), String> {
    let apply = || -> io::Result<()> {
        std::fs::create_dir_all(path)?;
        let descriptor = Descriptor::current_user()?;
        let path = wide(path.as_os_str());
        let mut dacl = null_mut();
        let mut present = 0;
        let mut defaulted = 0;
        if unsafe {
            GetSecurityDescriptorDacl(descriptor.0, &mut present, &mut dacl, &mut defaulted)
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        if present == 0 || dacl.is_null() {
            return Err(io::Error::other("private directory descriptor has no DACL"));
        }
        // Unlike SetFileSecurityW, this updates inherited permissions on
        // existing children as well as setting inheritance for new files.
        let error = unsafe {
            SetNamedSecurityInfoW(
                path.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                dacl,
                null_mut(),
            )
        };
        if error != 0 {
            return Err(io::Error::from_raw_os_error(error as i32));
        }
        Ok(())
    };
    apply().map_err(|e| format!("private directory {}: {e}", path.display()))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicU64, Ordering};
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Security::Authorization::{
        ConvertSecurityDescriptorToStringSecurityDescriptorW, GetNamedSecurityInfoW,
        GetSecurityInfo, SE_KERNEL_OBJECT,
    };
    use windows_sys::Win32::Security::{
        ACCESS_ALLOWED_ACE, GENERIC_MAPPING, GetAce, GetSecurityDescriptorControl,
        INHERIT_ONLY_ACE, MapGenericMask, SE_DACL_PROTECTED,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ALL_ACCESS, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    };

    fn descriptor_sddl(descriptor: &Descriptor) -> String {
        unsafe {
            let mut sddl = null_mut();
            let mut count = 0;
            if ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor.0,
                SDDL_REVISION_1,
                DACL_SECURITY_INFORMATION,
                &mut sddl,
                &mut count,
            ) == 0
            {
                return format!("<SDDL unavailable: {}>", io::Error::last_os_error());
            }
            let text = String::from_utf16_lossy(std::slice::from_raw_parts(sddl, count as usize))
                .trim_end_matches('\0')
                .to_string();
            LocalFree(sddl.cast());
            text
        }
    }

    fn assert_user_and_system(descriptor: &Descriptor, protected: bool, label: &str) {
        let context = format!("ACL for {label}: {}", descriptor_sddl(descriptor));
        // ACLs contain permission metadata only; never print file contents.
        eprintln!("{context}");
        unsafe {
            let mut control = 0;
            let mut revision = 0;
            assert_ne!(
                GetSecurityDescriptorControl(descriptor.0, &mut control, &mut revision),
                0,
                "{context}"
            );
            if protected {
                assert_ne!(control & SE_DACL_PROTECTED, 0, "{context}");
            }
            let mut dacl = null_mut();
            let mut present = 0;
            let mut defaulted = 0;
            assert_ne!(
                GetSecurityDescriptorDacl(descriptor.0, &mut present, &mut dacl, &mut defaulted),
                0,
                "{context}"
            );
            assert_ne!(present, 0, "{context}");
            assert!(
                !dacl.is_null(),
                "a NULL DACL would grant access to everyone; {context}"
            );
            let mut rights =
                BTreeMap::from([(user_sid().unwrap(), 0u32), ("S-1-5-18".into(), 0u32)]);
            let mapping = GENERIC_MAPPING {
                GenericRead: FILE_GENERIC_READ,
                GenericWrite: FILE_GENERIC_WRITE,
                GenericExecute: FILE_GENERIC_EXECUTE,
                GenericAll: FILE_ALL_ACCESS,
            };
            for i in 0..u32::from((*dacl).AceCount) {
                let mut ace = null_mut();
                assert_ne!(GetAce(dacl, i, &mut ace), 0, "{context}");
                let ace = &*ace.cast::<ACCESS_ALLOWED_ACE>();
                assert_eq!(
                    ace.Header.AceType, 0,
                    "only ACCESS_ALLOWED_ACE_TYPE expected; {context}"
                );
                assert_ne!(ace.Mask, 0, "empty ACE; {context}");
                let mut sid = null_mut();
                assert_ne!(
                    ConvertSidToStringSidW(
                        std::ptr::addr_of!(ace.SidStart).cast_mut().cast(),
                        &mut sid
                    ),
                    0,
                    "{context}"
                );
                let mut len = 0;
                while *sid.add(len) != 0 {
                    len += 1;
                }
                let sid_text = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
                LocalFree(sid.cast());
                let Some(effective) = rights.get_mut(&sid_text) else {
                    panic!("unexpected principal {sid_text}; {context}");
                };
                // Windows may split GA+OI+CI into an effective mapped ACE and
                // an inherit-only generic ACE. Only effective entries grant
                // rights on this object; inheritance-only entries must still
                // refer exclusively to the same two permitted principals.
                if u32::from(ace.Header.AceFlags) & INHERIT_ONLY_ACE == 0 {
                    let mut mask = ace.Mask;
                    MapGenericMask(&mut mask, &mapping);
                    *effective |= mask;
                }
            }
            for (sid, effective) in rights {
                assert_eq!(
                    effective & FILE_ALL_ACCESS,
                    FILE_ALL_ACCESS,
                    "{sid} does not have effective full control; {context}"
                );
            }
        }
    }

    pub(crate) fn assert_pipe_acl(handle: HANDLE) {
        let mut descriptor = null_mut();
        assert_eq!(
            unsafe {
                GetSecurityInfo(
                    handle,
                    SE_KERNEL_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    &mut descriptor,
                )
            },
            0
        );
        assert_user_and_system(&Descriptor(descriptor), true, "named pipe handle");
    }

    fn assert_file_acl(path: &Path, protected: bool) {
        let label = path.display().to_string();
        let path = wide(path.as_os_str());
        let mut descriptor = null_mut();
        assert_eq!(
            unsafe {
                GetNamedSecurityInfoW(
                    path.as_ptr(),
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    null_mut(),
                    &mut descriptor,
                )
            },
            0
        );
        assert_user_and_system(&Descriptor(descriptor), protected, &label);
    }

    #[test]
    fn security_descriptor_is_private_and_handles_are_not_inheritable() {
        let descriptor = Descriptor::current_user().unwrap();
        assert_user_and_system(&descriptor, true, "new private descriptor");
        let attrs = descriptor.attributes();
        assert_eq!(attrs.bInheritHandle, 0);
        assert_eq!(attrs.nLength as usize, size_of::<SECURITY_ATTRIBUTES>());
    }

    fn test_descriptor(sddl: &str) -> Descriptor {
        let sddl = wide(std::ffi::OsStr::new(sddl));
        let mut raw = null_mut();
        assert_ne!(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut raw,
                    null_mut(),
                )
            },
            0
        );
        Descriptor(raw)
    }

    #[test]
    #[should_panic(expected = "unexpected principal")]
    fn acl_assertion_rejects_access_for_everyone() {
        let descriptor = test_descriptor(&format!(
            "D:P(A;;GA;;;{})(A;;GA;;;SY)(A;;GR;;;WD)",
            user_sid().unwrap()
        ));
        assert_user_and_system(&descriptor, true, "negative test: Everyone must fail");
    }

    #[test]
    #[should_panic(expected = "does not have effective full control")]
    fn acl_assertion_does_not_count_inherit_only_full_control() {
        let sid = user_sid().unwrap();
        let system = if sid == "S-1-5-18" {
            ""
        } else {
            "(A;;GA;;;SY)"
        };
        let descriptor =
            test_descriptor(&format!("D:P(A;;GR;;;{sid})(A;OICIIO;GA;;;{sid}){system}"));
        assert_user_and_system(
            &descriptor,
            true,
            "negative test: inherit-only full control must fail",
        );
    }

    #[test]
    fn acl_assertion_accepts_split_effective_and_inherit_only_entries() {
        let sid = user_sid().unwrap();
        let descriptor = test_descriptor(&format!(
            "D:P(A;;FA;;;{sid})(A;OICIIO;GA;;;{sid})(A;;FA;;;SY)(A;OICIIO;GA;;;SY)"
        ));
        assert_user_and_system(&descriptor, true, "split generic inheritance entries");
    }

    #[test]
    fn private_directory_protects_new_and_preexisting_children() {
        static ID: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "oliv-acl-{}-{}-{}-ไทย",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        std::fs::create_dir(&root).unwrap();
        let old = root.join("before.txt");
        std::fs::write(&old, b"synthetic ACL fixture").unwrap();
        private_dir(&root).unwrap();
        assert_file_acl(&root, true);
        assert_file_acl(&old, false);
        let sub = root.join("เสียง");
        std::fs::create_dir(&sub).unwrap();
        let new = sub.join("after.txt");
        std::fs::write(&new, b"synthetic ACL fixture").unwrap();
        assert_file_acl(&sub, false);
        assert_file_acl(&new, false);
        private_dir(&root).unwrap();
        assert_file_acl(&old, false);
        assert_file_acl(&new, false);
    }
}

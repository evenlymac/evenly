//! Тестовый клиент APO: повторяет то, что делает audiodg.exe при создании APO (агрегация через
//! IClassFactory::CreateInstance(outer, IID_IUnknown)), и печатает каждый шаг. При аварии
//! векторный обработчик пишет адрес, модуль и смещение.
use std::ffi::c_void;
use windows::core::{implement, Interface, GUID, HRESULT, IUnknown, PCWSTR};
use windows::Win32::Foundation::{HMODULE, EXCEPTION_ACCESS_VIOLATION};
use windows::Win32::Media::Audio::Apo::*;
use windows::Win32::System::Com::IClassFactory;
use windows::Win32::System::Diagnostics::Debug::{AddVectoredExceptionHandler, EXCEPTION_POINTERS};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, GetModuleHandleExW, GetProcAddress, LoadLibraryW, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
};

const CLSID_EVENLY_APO: GUID = GUID::from_u128(0x5b1a5c4e_3b0e_4f4f_9a3e_ee1e0a9d0001);

#[implement(IAudioSystemEffects)]
struct Outer;
impl IAudioSystemEffects_Impl for Outer_Impl {}

unsafe extern "system" fn on_exception(p: *mut EXCEPTION_POINTERS) -> i32 {
    let rec = &*(*p).ExceptionRecord;
    let addr = rec.ExceptionAddress as *const c_void;
    let mut m = HMODULE::default();
    let _ = GetModuleHandleExW(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        PCWSTR(addr as *const u16),
        &mut m,
    );
    let mut buf = [0u16; 520];
    let n = GetModuleFileNameW(Some(m), &mut buf) as usize;
    let name = String::from_utf16_lossy(&buf[..n]);
    if rec.ExceptionCode.0 as u32 == EXCEPTION_ACCESS_VIOLATION.0 as u32 || rec.ExceptionCode.0 as u32 >= 0xC000_0000 {
        println!(
            "!! EXCEPTION code={:#x} addr={:p} module={} offset={:#x} info0={:#x} info1={:#x}",
            rec.ExceptionCode.0 as u32,
            addr,
            name,
            addr as usize - m.0 as usize,
            rec.ExceptionInformation[0],
            rec.ExceptionInformation[1]
        );
    }
    0
}

fn step(s: &str) {
    println!("step: {s}");
}

fn main() {
    let dll = std::env::args().nth(1).expect("usage: apo-harness <evenly_apo.dll>");
    unsafe {
        AddVectoredExceptionHandler(1, Some(on_exception));
        step("LoadLibrary");
        let w: Vec<u16> = dll.encode_utf16().chain(Some(0)).collect();
        let lib = LoadLibraryW(PCWSTR(w.as_ptr())).expect("LoadLibrary");
        let proc = GetProcAddress(lib, windows::core::s!("DllGetClassObject")).expect("DllGetClassObject");
        let get: unsafe extern "system" fn(*const GUID, *const GUID, *mut *mut c_void) -> HRESULT = std::mem::transmute(proc);

        step("DllGetClassObject");
        let mut pf: *mut c_void = std::ptr::null_mut();
        get(&CLSID_EVENLY_APO, &IClassFactory::IID, &mut pf).ok().expect("get class object");
        let factory = IClassFactory::from_raw(pf);

        let outer: IUnknown = Outer.into();

        step("CreateInstance(outer, IID_IUnknown)");
        let inner: IUnknown = factory.CreateInstance(&outer).expect("CreateInstance aggregated");
        step("CreateInstance returned");

        step("QI inner -> IAudioProcessingObject");
        let apo: IAudioProcessingObject = inner.cast().expect("QI IAudioProcessingObject");
        step("GetLatency");
        println!("latency={:?}", apo.GetLatency());
        step("GetRegistrationProperties");
        let p = apo.GetRegistrationProperties().expect("GetRegistrationProperties");
        println!("reg clsid={:?} ifaces={}", (*p).clsid, (*p).u32NumAPOInterfaces);
        windows::Win32::System::Com::CoTaskMemFree(Some(p as *const c_void));
        step("Initialize");
        println!("init={:?}", apo.Initialize(&[]));
        step("QI inner -> IAudioProcessingObjectRT");
        let rt: IAudioProcessingObjectRT = inner.cast().expect("QI RT");
        println!("calc out={}", rt.CalcOutputFrames(480));
        step("QI inner -> IAudioProcessingObjectConfiguration");
        let _cfg: IAudioProcessingObjectConfiguration = inner.cast().expect("QI cfg");
        step("QI inner -> IAudioSystemEffects");
        let _fx: IAudioSystemEffects = inner.cast().expect("QI fx");

        step("release interfaces");
        drop(_fx);
        drop(_cfg);
        drop(rt);
        drop(apo);
        step("release inner");
        drop(inner);
        step("release outer/factory");
        drop(outer);
        drop(factory);
        step("OK");
    }
}

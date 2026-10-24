//! Тестовый клиент APO: повторяет то, что делает audiodg.exe при создании APO (агрегация через
//! IClassFactory::CreateInstance(outer, IID_IUnknown)), и печатает каждый шаг. При аварии
//! векторный обработчик пишет адрес, модуль и смещение. Потом гоняет звук через APO и сверяет
//! с эталоном (тот же Normalizer напрямую).
use std::ffi::c_void;
use windows::core::{implement, Interface, Ref, Result as WinResult, BOOL, GUID, HRESULT, IUnknown, PCWSTR};
use windows::Win32::Foundation::{HMODULE, EXCEPTION_ACCESS_VIOLATION};
use windows::Win32::Media::Audio::Apo::*;
use windows::Win32::System::Com::IClassFactory;
use windows::Win32::System::Diagnostics::Debug::{AddVectoredExceptionHandler, EXCEPTION_POINTERS};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, GetModuleHandleExW, GetProcAddress, LoadLibraryW, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
};

const CLSID_EVENLY_APO: GUID = GUID::from_u128(0x5b1a5c4e_3b0e_4f4f_9a3e_ee1e0a9d0001);
const FLOAT_SUBTYPE: GUID = GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71);

#[implement(IAudioMediaType)]
struct Fmt {
    channels: u32,
    rate: f32,
}
impl IAudioMediaType_Impl for Fmt_Impl {
    fn IsCompressedFormat(&self) -> WinResult<BOOL> {
        Ok(BOOL(0))
    }
    fn IsEqual(&self, _other: Ref<'_, IAudioMediaType>) -> WinResult<u32> {
        Ok(0)
    }
    fn GetAudioFormat(&self) -> *mut windows::Win32::Media::Audio::WAVEFORMATEX {
        std::ptr::null_mut()
    }
    fn GetUncompressedAudioFormat(&self, p: *mut UNCOMPRESSEDAUDIOFORMAT) -> WinResult<()> {
        unsafe {
            *p = UNCOMPRESSEDAUDIOFORMAT {
                guidFormatType: FLOAT_SUBTYPE,
                dwSamplesPerFrame: self.channels,
                dwBytesPerSampleContainer: 4,
                dwValidBitsPerSample: 32,
                fFramesPerSecond: self.rate,
                dwChannelMask: 3,
            };
        }
        Ok(())
    }
}

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

        step("process: LockForProcess + APOProcess vs evenly-dsp reference");
        process_test(&_cfg, &rt);
        println!("latency after lock={:?}", apo.GetLatency());

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

/// Прогон через APO (стерео 48 кГц, блоки по 480 кадров, на месте) против эталона: тот же Normalizer напрямую.
/// Тихий вход, потом громкий, потом блоки с флагом SILENT (тишина должна идти через ядро).
unsafe fn process_test(cfg: &IAudioProcessingObjectConfiguration, rt: &IAudioProcessingObjectRT) {
    use evenly_dsp::Normalizer;
    const CH: usize = 2;
    const FRAMES: usize = 480;
    let fmt: IAudioMediaType = Fmt { channels: CH as u32, rate: 48000.0 }.into();
    let mut buf = vec![0.0f32; FRAMES * CH];
    let mk = |buf: &mut Vec<f32>| APO_CONNECTION_DESCRIPTOR {
        Type: APO_CONNECTION_BUFFER_TYPE_EXTERNAL,
        pBuffer: buf.as_mut_ptr() as usize,
        u32MaxFrameCount: FRAMES as u32,
        pFormat: std::mem::ManuallyDrop::new(Some(fmt.clone())),
        u32Signature: 0x41_50_4F_43, // 'APOC'
    };
    let din = mk(&mut buf);
    let dout = mk(&mut buf);
    let (pin, pout) = ([&din as *const APO_CONNECTION_DESCRIPTOR], [&dout as *const APO_CONNECTION_DESCRIPTOR]);
    cfg.LockForProcess(&pin, &pout).expect("LockForProcess");

    let mut reference = Normalizer::new(CH, 48000.0);
    let mut max_diff = 0.0f32;
    let mut peak = 0.0f32;
    let mut inp = APO_CONNECTION_PROPERTY { pBuffer: buf.as_mut_ptr() as usize, u32ValidFrameCount: FRAMES as u32, u32BufferFlags: BUFFER_VALID, u32Signature: 0x41_50_4F_50 };
    let mut out = inp;
    let total_blocks = 48000 * 6 / FRAMES;
    for b in 0..total_blocks {
        let silent = b >= total_blocks - 20;
        let amp = if b < total_blocks / 2 { 0.01f32 } else { 0.9 };
        let mut expect = vec![0.0f32; FRAMES * CH];
        for i in 0..FRAMES * CH {
            let p = ((b * FRAMES * CH + i) % 100) as f32;
            let v = if silent { 0.0 } else { (1.0 - 2.0 * (2.0 * p - 100.0).abs() / 100.0) * amp };
            buf[i] = if silent { 12345.0 } else { v }; // при SILENT содержимое буфера не определено
            expect[i] = v;
        }
        reference.process_interleaved(&mut expect);
        inp.u32BufferFlags = if silent { BUFFER_SILENT } else { BUFFER_VALID };
        out.u32BufferFlags = BUFFER_INVALID;
        let pi = [&inp as *const APO_CONNECTION_PROPERTY];
        let mut po = [&mut out as *mut APO_CONNECTION_PROPERTY];
        rt.APOProcess(1, pi.as_ptr(), 1, po.as_mut_ptr());
        assert_eq!(out.u32ValidFrameCount, FRAMES as u32, "frames");
        for i in 0..FRAMES * CH {
            max_diff = max_diff.max((buf[i] - expect[i]).abs());
            peak = peak.max(buf[i].abs());
        }
    }
    println!("process: blocks={total_blocks} max diff vs reference = {max_diff:e}, output peak={peak:.4}");
    assert!(max_diff == 0.0, "APO output differs from reference");
    cfg.UnlockForProcess().expect("Unlock");
    for d in [din, dout] {
        drop(std::mem::ManuallyDrop::into_inner(d.pFormat));
    }
}

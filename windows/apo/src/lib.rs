//! Evenly APO, этап 2: пустышка. Пропускает звук без изменений и пишет журнал
//! `C:\ProgramData\Evenly\apo.log` (формат, число вызовов, пик), чтобы убедиться,
//! что `audiodg.exe` загрузил DLL без подписи и звук идёт через неё.
#![allow(non_snake_case, clippy::missing_safety_doc)]

use std::ffi::c_void;
use std::io::Write;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

use evenly_dsp::Normalizer;

use windows::core::{implement, Error, Ref, Result, BOOL, GUID, HRESULT, IUnknown, Interface};
use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_INVALIDARG, E_NOTIMPL, E_POINTER, HINSTANCE,
    S_FALSE, S_OK,
};
use windows::Win32::Media::Audio::Apo::*;
use windows::Win32::System::Com::{CoTaskMemAlloc, IClassFactory, IClassFactory_Impl};
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::Registry::*;
use windows::Win32::System::SystemServices::DLL_PROCESS_ATTACH;

/// CLSID APO Evenly.
pub const CLSID_EVENLY_APO: GUID = GUID::from_u128(0x5b1a5c4e_3b0e_4f4f_9a3e_ee1e0a9d0001);
const FRIENDLY: &str = "Evenly";
const FLOAT_SUBTYPE: GUID = GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71); // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
const LOG_PATH: &str = r"C:\ProgramData\Evenly\apo.log";

static MODULE: AtomicU64 = AtomicU64::new(0);
static LOG_LOCK: Mutex<()> = Mutex::new(());

fn log(msg: &str) {
    let _g = LOG_LOCK.lock();
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(LOG_PATH) {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = writeln!(f, "{t} pid={} {msg}", std::process::id());
    }
}

fn apo_flags() -> APO_FLAG {
    APO_FLAG(APO_FLAG_INPLACE.0 | APO_FLAG_FRAMESPERSECOND_MUST_MATCH.0 | APO_FLAG_BITSPERSAMPLE_MUST_MATCH.0 | APO_FLAG_SAMPLESPERFRAME_MUST_MATCH.0)
}

fn interfaces() -> [GUID; 3] {
    [IAudioProcessingObject::IID, IAudioProcessingObjectRT::IID, IAudioProcessingObjectConfiguration::IID]
}

fn wide<const N: usize>(s: &str) -> [u16; N] {
    let mut out = [0u16; N];
    for (i, c) in s.encode_utf16().take(N - 1).enumerate() {
        out[i] = c;
    }
    out
}

#[implement(IAudioProcessingObject, IAudioProcessingObjectRT, IAudioProcessingObjectConfiguration, IAudioSystemEffects)]
struct EvenlyApo {
    channels: AtomicU32,
    rate: AtomicU32,
    calls: AtomicU64,
    peak_bits: AtomicU32,
    /// Нормализатор создаётся в LockForProcess и живёт до UnlockForProcess; try_lock в потоке реального времени.
    norm: Mutex<Option<Normalizer>>,
}

impl EvenlyApo {
    fn new() -> Self {
        EvenlyApo {
            channels: AtomicU32::new(0),
            rate: AtomicU32::new(0),
            calls: AtomicU64::new(0),
            peak_bits: AtomicU32::new(0),
            norm: Mutex::new(None),
        }
    }
}

impl IAudioProcessingObject_Impl for EvenlyApo_Impl {
    fn Reset(&self) -> Result<()> {
        Ok(())
    }

    fn GetLatency(&self) -> Result<i64> {
        // опережение ядра: 512 сэмплов потока interleaved (единое состояние на все каналы), в единицах 100 нс
        let (ch, rate) = (self.channels.load(Ordering::Relaxed), self.rate.load(Ordering::Relaxed));
        if ch == 0 || rate == 0 {
            return Ok(0);
        }
        Ok((evenly_dsp::ChannelCompressor::LOOKAHEAD as i64 * 10_000_000) / (ch as i64 * rate as i64))
    }

    fn GetRegistrationProperties(&self) -> Result<*mut APO_REG_PROPERTIES> {
        log("GetRegistrationProperties");
        let ifs = interfaces();
        let size = std::mem::size_of::<APO_REG_PROPERTIES>() + (ifs.len() - 1) * std::mem::size_of::<GUID>();
        unsafe {
            let p = CoTaskMemAlloc(size) as *mut APO_REG_PROPERTIES;
            if p.is_null() {
                return Err(Error::from(E_POINTER));
            }
            std::ptr::write_bytes(p as *mut u8, 0, size);
            (*p).clsid = CLSID_EVENLY_APO;
            (*p).Flags = apo_flags();
            (*p).szFriendlyName = wide::<256>(FRIENDLY);
            (*p).szCopyrightInfo = wide::<256>("Evenly");
            (*p).u32MajorVersion = 0;
            (*p).u32MinorVersion = 2;
            (*p).u32MinInputConnections = 1;
            (*p).u32MaxInputConnections = 1;
            (*p).u32MinOutputConnections = 1;
            (*p).u32MaxOutputConnections = 1;
            (*p).u32MaxInstances = 0xffff_ffff;
            (*p).u32NumAPOInterfaces = ifs.len() as u32;
            let list = std::ptr::addr_of_mut!((*p).iidAPOInterfaceList) as *mut GUID;
            for (i, g) in ifs.iter().enumerate() {
                list.add(i).write(*g);
            }
            Ok(p)
        }
    }

    fn Initialize(&self, _cbdatasize: u32, _pbydata: *const u8) -> Result<()> {
        log("Initialize");
        Ok(())
    }

    fn IsInputFormatSupported(&self, _opposite: Ref<'_, IAudioMediaType>, requested: Ref<'_, IAudioMediaType>) -> Result<IAudioMediaType> {
        log("IsInputFormatSupported");
        check_format(requested)
    }

    fn IsOutputFormatSupported(&self, _opposite: Ref<'_, IAudioMediaType>, requested: Ref<'_, IAudioMediaType>) -> Result<IAudioMediaType> {
        log("IsOutputFormatSupported");
        check_format(requested)
    }

    fn GetInputChannelCount(&self) -> Result<u32> {
        log("GetInputChannelCount");
        Ok(self.channels.load(Ordering::Relaxed).max(1))
    }
}

/// Принимаем только float32 (так движок и отдаёт на SFX/MFX/EFX).
fn check_format(requested: Ref<'_, IAudioMediaType>) -> Result<IAudioMediaType> {
    let fmt = requested.ok()?;
    let mut f = UNCOMPRESSEDAUDIOFORMAT::default();
    unsafe { fmt.GetUncompressedAudioFormat(&mut f)? };
    if f.guidFormatType == FLOAT_SUBTYPE {
        Ok(fmt.clone())
    } else {
        log(&format!("формат не float32: {:?}", f.guidFormatType));
        Err(Error::from(APOERR_FORMAT_NOT_SUPPORTED))
    }
}

impl IAudioProcessingObjectRT_Impl for EvenlyApo_Impl {
    fn APOProcess(
        &self,
        _numin: u32,
        inputs: *const *const APO_CONNECTION_PROPERTY,
        _numout: u32,
        outputs: *mut *mut APO_CONNECTION_PROPERTY,
    ) {
        unsafe {
            let inp = &**inputs;
            let out = &mut **outputs;
            let ch = self.channels.load(Ordering::Relaxed).max(1) as usize;
            let n = inp.u32ValidFrameCount as usize * ch;
            let silent = inp.u32BufferFlags == BUFFER_SILENT;
            let mut flags = inp.u32BufferFlags;
            if out.pBuffer != 0 && (silent || inp.pBuffer != 0) {
                let dst = std::slice::from_raw_parts_mut(out.pBuffer as *mut f32, n);
                if silent {
                    // тишину тоже пропускаем через ядро: в опережении может быть хвост, а состояние должно идти дальше
                    dst.fill(0.0);
                    flags = BUFFER_VALID;
                } else if out.pBuffer != inp.pBuffer {
                    std::ptr::copy_nonoverlapping(inp.pBuffer as *const f32, dst.as_mut_ptr(), n);
                }
                if let Ok(mut g) = self.norm.try_lock() {
                    if let Some(norm) = g.as_mut() {
                        norm.process_interleaved(dst);
                    }
                }
                // пик блока (для журнала)
                let mut pk = 0.0f32;
                for v in dst.iter() {
                    pk = pk.max(v.abs());
                }
                if pk > f32::from_bits(self.peak_bits.load(Ordering::Relaxed)) {
                    self.peak_bits.store(pk.to_bits(), Ordering::Relaxed);
                }
            }
            out.u32ValidFrameCount = inp.u32ValidFrameCount;
            out.u32BufferFlags = flags;
            let c = self.calls.fetch_add(1, Ordering::Relaxed) + 1;
            if c == 1 || c % 500 == 0 {
                let pk = f32::from_bits(self.peak_bits.swap(0, Ordering::Relaxed));
                log(&format!("APOProcess #{c} frames={} silent={silent} peak={pk:.4}", inp.u32ValidFrameCount));
            }
        }
    }

    fn CalcInputFrames(&self, outputframecount: u32) -> u32 {
        outputframecount
    }

    fn CalcOutputFrames(&self, inputframecount: u32) -> u32 {
        inputframecount
    }
}

impl IAudioProcessingObjectConfiguration_Impl for EvenlyApo_Impl {
    fn LockForProcess(
        &self,
        numin: u32,
        inputs: *const *const APO_CONNECTION_DESCRIPTOR,
        _numout: u32,
        _outputs: *const *const APO_CONNECTION_DESCRIPTOR,
    ) -> Result<()> {
        if numin == 0 || inputs.is_null() {
            return Err(Error::from(E_INVALIDARG));
        }
        unsafe {
            let d = &**inputs;
            if let Some(fmt) = d.pFormat.as_ref() {
                let mut f = UNCOMPRESSEDAUDIOFORMAT::default();
                fmt.GetUncompressedAudioFormat(&mut f)?;
                self.channels.store(f.dwSamplesPerFrame, Ordering::Relaxed);
                self.rate.store(f.fFramesPerSecond as u32, Ordering::Relaxed);
                if let Ok(mut g) = self.norm.lock() {
                    *g = Some(Normalizer::new(f.dwSamplesPerFrame.max(1) as usize, f.fFramesPerSecond as f64));
                }
                log(&format!(
                    "LockForProcess channels={} rate={} maxframes={}",
                    f.dwSamplesPerFrame, f.fFramesPerSecond, d.u32MaxFrameCount
                ));
            }
        }
        Ok(())
    }

    fn UnlockForProcess(&self) -> Result<()> {
        log("UnlockForProcess");
        if let Ok(mut g) = self.norm.lock() {
            *g = None;
        }
        Ok(())
    }
}

impl IAudioSystemEffects_Impl for EvenlyApo_Impl {}

#[implement(IClassFactory)]
struct Factory;

/// audiodg.exe создаёт APO агрегированно (внешний IUnknown не null, riid = IID_IUnknown):
/// возвращаем внутренний «неделегирующий» IUnknown, который отдаёт интерфейсы объекта.
#[repr(C)]
struct AggVtbl {
    query_interface: unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> HRESULT,
    add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
}

#[repr(C)]
struct Aggregate {
    vtbl: *const AggVtbl,
    refs: AtomicU32,
    obj: IUnknown,
}

unsafe extern "system" fn agg_qi(this: *mut c_void, riid: *const GUID, ppv: *mut *mut c_void) -> HRESULT {
    if riid.is_null() || ppv.is_null() {
        return E_POINTER;
    }
    let agg = &*(this as *const Aggregate);
    if *riid == IUnknown::IID {
        agg.refs.fetch_add(1, Ordering::AcqRel);
        *ppv = this;
        log("agg QI IUnknown");
        return S_OK;
    }
    let hr = agg.obj.query(riid, ppv);
    log(&format!("agg QI {:?} -> {:?}", *riid, hr));
    hr
}

unsafe extern "system" fn agg_add_ref(this: *mut c_void) -> u32 {
    log("agg AddRef");
    (*(this as *const Aggregate)).refs.fetch_add(1, Ordering::AcqRel) + 1
}

unsafe extern "system" fn agg_release(this: *mut c_void) -> u32 {
    log("agg Release");
    let n = (*(this as *const Aggregate)).refs.fetch_sub(1, Ordering::AcqRel) - 1;
    if n == 0 {
        drop(Box::from_raw(this as *mut Aggregate));
    }
    n
}

static AGG_VTBL: AggVtbl = AggVtbl { query_interface: agg_qi, add_ref: agg_add_ref, release: agg_release };

impl IClassFactory_Impl for Factory_Impl {
    fn CreateInstance(&self, outer: Ref<'_, IUnknown>, riid: *const GUID, ppv: *mut *mut c_void) -> Result<()> {
        let has_outer = outer.as_ref().is_some();
        log(&format!("CreateInstance enter has_outer={has_outer} riid={:?}", unsafe { *riid }));
        let unk: IUnknown = EvenlyApo::new().into();
        if has_outer {
            if unsafe { *riid } != IUnknown::IID {
                return Err(Error::from(CLASS_E_NOAGGREGATION));
            }
            let agg = Box::new(Aggregate { vtbl: &AGG_VTBL, refs: AtomicU32::new(1), obj: unk });
            unsafe { *ppv = Box::into_raw(agg) as *mut c_void };
            log("CreateInstance -> aggregated");
            return Ok(());
        }
        let hr = unsafe { unk.query(riid, ppv) };
        log(&format!("CreateInstance -> {:?}", hr));
        hr.ok()
    }

    fn LockServer(&self, _lock: BOOL) -> Result<()> {
        Ok(())
    }
}

#[no_mangle]
pub unsafe extern "system" fn DllMain(hinst: HINSTANCE, reason: u32, _reserved: *mut c_void) -> BOOL {
    if reason == DLL_PROCESS_ATTACH {
        MODULE.store(hinst.0 as u64, Ordering::Relaxed);
        let mut buf = [0u16; 520];
        let len = GetModuleFileNameW(None, &mut buf) as usize;
        log(&format!("DllMain attach in {}", String::from_utf16_lossy(&buf[..len])));
    }
    BOOL(1)
}

#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(rclsid: *const GUID, riid: *const GUID, ppv: *mut *mut c_void) -> HRESULT {
    if rclsid.is_null() || riid.is_null() || ppv.is_null() {
        return E_POINTER;
    }
    log(&format!("DllGetClassObject clsid={:?} riid={:?}", *rclsid, *riid));
    if *rclsid != CLSID_EVENLY_APO {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    let f: IClassFactory = Factory.into();
    let hr = f.query(riid, ppv);
    log(&format!("DllGetClassObject -> {:?}", hr));
    hr
}

#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_FALSE
}

// ---- регистрация (regsvr32 evenly_apo.dll / regsvr32 /u) ----

fn guid_str(g: &GUID) -> String {
    format!("{{{:?}}}", g).replace("{{", "{").replace("}}", "}").to_uppercase()
}

fn set_str(key: HKEY, name: &str, value: &str) -> Result<()> {
    let n: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    let v: Vec<u16> = value.encode_utf16().chain(Some(0)).collect();
    let bytes = unsafe { std::slice::from_raw_parts(v.as_ptr() as *const u8, v.len() * 2) };
    unsafe { RegSetValueExW(key, windows::core::PCWSTR(n.as_ptr()), None, REG_SZ, Some(bytes)).ok() }
}

fn set_dword(key: HKEY, name: &str, value: u32) -> Result<()> {
    let n: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    unsafe { RegSetValueExW(key, windows::core::PCWSTR(n.as_ptr()), None, REG_DWORD, Some(&value.to_le_bytes())).ok() }
}

fn create(path: &str) -> Result<HKEY> {
    let p: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    let mut k = HKEY::default();
    unsafe {
        RegCreateKeyExW(HKEY_LOCAL_MACHINE, windows::core::PCWSTR(p.as_ptr()), None, windows::core::PCWSTR::null(),
            REG_OPTION_NON_VOLATILE, KEY_WRITE, None, &mut k, None).ok()?;
    }
    Ok(k)
}

fn delete_tree(path: &str) {
    let p: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    unsafe { let _ = RegDeleteTreeW(HKEY_LOCAL_MACHINE, windows::core::PCWSTR(p.as_ptr())); }
}

fn register() -> Result<()> {
    let clsid = guid_str(&CLSID_EVENLY_APO);
    let mut buf = [0u16; 520];
    let len = unsafe { GetModuleFileNameW(Some(windows::Win32::Foundation::HMODULE(MODULE.load(Ordering::Relaxed) as *mut c_void)), &mut buf) } as usize;
    let dll = String::from_utf16_lossy(&buf[..len]);

    let k = create(&format!(r"SOFTWARE\Classes\CLSID\{clsid}"))?;
    set_str(k, "", FRIENDLY)?;
    let k = create(&format!(r"SOFTWARE\Classes\CLSID\{clsid}\InprocServer32"))?;
    set_str(k, "", &dll)?;
    set_str(k, "ThreadingModel", "Both")?;

    let k = create(&format!(r"SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\{clsid}"))?;
    set_str(k, "FriendlyName", FRIENDLY)?;
    set_str(k, "Copyright", "Evenly")?;
    set_dword(k, "MajorVersion", 0)?;
    set_dword(k, "MinorVersion", 2)?;
    set_dword(k, "Flags", apo_flags().0 as u32)?;
    set_dword(k, "MinInputConnections", 1)?;
    set_dword(k, "MaxInputConnections", 1)?;
    set_dword(k, "MinOutputConnections", 1)?;
    set_dword(k, "MaxOutputConnections", 1)?;
    set_dword(k, "MaxInstances", 0xffff_ffff)?;
    let ifs = interfaces();
    set_dword(k, "NumAPOInterfaces", ifs.len() as u32)?;
    for (i, g) in ifs.iter().enumerate() {
        set_str(k, &format!("APOInterface{i}"), &guid_str(g))?;
    }
    Ok(())
}

#[no_mangle]
pub extern "system" fn DllRegisterServer() -> HRESULT {
    match register() {
        Ok(()) => S_OK,
        Err(e) => e.code(),
    }
}

#[no_mangle]
pub extern "system" fn DllUnregisterServer() -> HRESULT {
    let clsid = guid_str(&CLSID_EVENLY_APO);
    delete_tree(&format!(r"SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\{clsid}"));
    delete_tree(&format!(r"SOFTWARE\Classes\CLSID\{clsid}"));
    S_OK
}

#[allow(dead_code)]
fn _unused() -> HRESULT {
    E_NOTIMPL
}

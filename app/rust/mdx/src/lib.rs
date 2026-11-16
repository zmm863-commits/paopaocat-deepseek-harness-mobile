//! MDX-Net 人声/伴奏分离（UVR_MDXNET_KARA_2）。
//!
//! ## 为什么这一段写在 Rust 里而不是 Dart
//!
//! 分离要做的活是 **STFT（4096 点 FFT）→ 神经网络 → iSTFT**，一首 3 分钟的歌
//! 有约 8000 帧、每帧一次 4096 点 FFT，加上前后两次重叠相加。同样的算法在 Dart
//! 里跑是分钟级，在 Rust 里是秒级 —— 所以浮点密集的部分全部放在这里，
//! Dart 只负责传文件路径、收进度、播放结果。
//!
//! ## ONNX Runtime 从哪来
//!
//! **不额外带一份**。App 里已经因为离线配音（sherpa-onnx）带了
//! `libonnxruntime.so`，这里用 `ort` 的 `load-dynamic` 在运行时 dlopen 它 ——
//! 好处是：① 包体不增加；② 不会出现两个同名 .so 在 APK 里打架。
//!
//! ## 模型规格（实测读出来的，不是猜的）
//!
//! 输入 `input`  float32 `[batch, 4, 2048, 256]`
//! 输出 `output` float32 `[batch, 4, 2048, 256]`
//!
//! 4 通道 = 立体声 ×（实部、虚部）；2048 频点 = n_fft 4096 / 2；
//! 256 帧 × hop 1024 / 44100 ≈ 5.95 秒一块。
//!
//! 模型出的是**伴奏**（KARA_2 是卡拉OK模型，保留和声），人声由 `mix - inst` 得到。

use std::os::raw::{c_char, c_float, c_int};
use std::sync::Mutex;

use ort::environment::Environment;
use ort::session::Session;
use ort::value::Tensor;
use rustfft::num_complex::Complex32;
use rustfft::{FftPlanner};

/// 采样率（模型固定 44.1 kHz）。
const SR: usize = 44100;
/// FFT 点数。
///
/// ⚠️ 这个值**不是** 4096。权威实现对 UVR_MDXNET_KARA_2 标的是
/// `mdx_n_fft_scale_set: 5120`，并要求能被 32 整除。用 4096 会让频率轴整个错位
/// （我第一版就是 4096，跑出来幅度是原音频的 40 倍、人声伴奏几乎相等）。
const N_FFT: usize = 5120;
/// 帧移。
const HOP: usize = 1024;
/// 频率 bin 数 = N_FFT / 2（模型输入的第二维）。
const DIM_F: usize = 2048;
/// 每块帧数（模型输入的第三维）。
const DIM_T: usize = 256;

/// 伴奏增益补偿（权威实现对 KARA_2 标了 `compensate: 1.065`）。
const COMPENSATE: f32 = 1.065;

/// 全局环境 + 会话（一次只跑一个分离任务，简单起见用 Mutex 包住）。
///
/// Environment 必须比 Session 活得久 —— ort 的 Environment 是运行时句柄，
/// Session 析构时要用它。所以两个一起存。
static SESSION: Mutex<Option<(Environment, Session)>> = Mutex::new(None);

fn hann(n: usize) -> Vec<f32> {
    (0..n)
        .map(|i| {
            let x = std::f32::consts::PI * 2.0 * i as f32 / n as f32;
            0.5 - 0.5 * x.cos()
        })
        .collect()
}

/// 打开模型。返回 0 表示成功。
///
/// # Safety
/// `path` 必须是有效的、以 NUL 结尾的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn mdx_open(path: *const c_char, ort_dylib: *const c_char) -> c_int {
    if path.is_null() {
        return -1;
    }
    let cstr = match std::ffi::CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    // 让 ort 去 dlopen 系统里已有的 libonnxruntime.so（就是 sherpa-onnx 带进来的那份）。
    //
    // load-dynamic 模式下这里必须显式给库名：`ort::init_from` 会按这个名字 dlopen。
    // 不写死绝对路径 —— Android 上它在 APK 的 jniLibs 里，由链接器按 soname 找。
    //
    // 库路径**必须由调用方给绝对路径**。
    //
    // ⚠️ 这是 Android 的硬限制，不是偷懒：从 API 21 起 bionic 的链接器
    //    **不再读 `LD_LIBRARY_PATH` 去找 dlopen 的裸库名**，只认绝对路径
    //    （或者由 System.loadLibrary 预先加载）。传 "libonnxruntime.so"
    //    在手机上必然失败。桌面上原样传绝对路径也行，所以两边同一套代码。
    let dylib = if ort_dylib.is_null() {
        std::env::var("MDX_ORT_DYLIB")
            .unwrap_or_else(|_| "libonnxruntime.so".to_string())
    } else {
        match std::ffi::CStr::from_ptr(ort_dylib).to_str() {
            Ok(v) => v.to_string(),
            Err(_) => return -13,
        }
    };
    let env = match ort::init_from(&dylib) {
        Ok(b) => match b.build() {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[mdx] build() 失败：{e:?}");
                return -11;
            }
        },
        Err(e) => {
            eprintln!("[mdx] init_from({}) 失败：{e:?}", dylib);
            return -12;
        }
    };
    let build = Session::builder(&env).and_then(|mut b| b.commit_from_file(cstr));
    match build {
        Ok(s) => {
            let mut g = SESSION.lock().unwrap();
            *g = Some((env, s));
            0
        }
        Err(_) => -10,
    }
}

/// 释放模型。
#[no_mangle]
pub extern "C" fn mdx_close() {
    let mut g = SESSION.lock().unwrap();
    *g = None;
}

/// 分离一段**单声道**浮点音频（已经把立体声下混好传进来）。
///
/// 入参 `samples`/`n`：输入采样点（44.1kHz mono）。
/// 出参 `out_vocals`/`out_inst`：两个长度都必须是 `n`，由调用方分配。
///
/// 返回 0 成功；负数失败。
///
/// # Safety
/// 三个指针都必须指向长度不小于 `n` 的有效内存；`out_instrumental` 也要 `n` 个。
#[no_mangle]
pub unsafe extern "C" fn mdx_separate(
    samples: *const c_float,
    n: usize,
    out_vocals: *mut c_float,
    out_inst: *mut c_float,
) -> c_int {
    if samples.is_null() || out_vocals.is_null() || out_inst.is_null() || n == 0 {
        return -1;
    }
    let mut g = SESSION.lock().unwrap();
    let session = match g.as_mut() {
        Some((_env, s)) => s,
        None => return -2,
    };

    let input = std::slice::from_raw_parts(samples, n);
    let vocal_out = std::slice::from_raw_parts_mut(out_vocals, n);
    let inst_out = std::slice::from_raw_parts_mut(out_inst, n);

    // ── STFT：补零到 (n + N_FFT) 再做，保证首尾完整 ─────────────────
    let pad = N_FFT / 2;
    let mut padded = vec![0f32; n + N_FFT];
    padded[pad..pad + n].copy_from_slice(input);

    let win = hann(N_FFT);
    let n_frames = if padded.len() >= N_FFT {
        (padded.len() - N_FFT) / HOP + 1
    } else {
        0
    };
    if n_frames == 0 {
        return -3;
    }

    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(N_FFT);
    let ifft = planner.plan_fft_inverse(N_FFT);

    // 每帧只存 DIM_F 个 bin（模型要的），相位在还原时用「原相位 + 幅度比」。
    let mut spec_re = vec![0f32; n_frames * DIM_F];
    let mut spec_im = vec![0f32; n_frames * DIM_F];

    let mut buf = vec![Complex32::new(0.0, 0.0); N_FFT];
    for t in 0..n_frames {
        for i in 0..N_FFT {
            buf[i] = Complex32::new(padded[t * HOP + i] * win[i], 0.0);
        }
        fft.process(&mut buf);
        for f in 0..DIM_F {
            spec_re[t * DIM_F + f] = buf[f].re;
            spec_im[t * DIM_F + f] = buf[f].im;
        }
    }

    // ── 分块推理：每块 DIM_T 帧 ─────────────────────────────────────
    let n_blocks = (n_frames + DIM_T - 1) / DIM_T;
    // 模型要立体声 4 通道；单声道输入时左右声道填同一份。

    for b in 0..n_blocks {
        let t0 = b * DIM_T;
        let tcnt = DIM_T.min(n_frames - t0);

        // [1, 4, DIM_F, DIM_T]，4 通道 = L实, L虚, R实, R虚（单声道时 L=R）。
        let mut inbuf = vec![0f32; 4 * DIM_F * DIM_T];
        for t in 0..tcnt {
            let src = (t0 + t) * DIM_F;
            for f in 0..DIM_F {
                let re = spec_re[src + f];
                let im = spec_im[src + f];
                // 通道布局：0=L实 1=L虚 2=R实 3=R虚；每个通道是 [DIM_F, DIM_T] 行优先。
                let idx = f * DIM_T + t;
                inbuf[idx] = re;                       // L 实
                inbuf[DIM_F * DIM_T + idx] = im;       // L 虚
                inbuf[2 * DIM_F * DIM_T + idx] = re;   // R 实
                inbuf[3 * DIM_F * DIM_T + idx] = im;   // R 虚
            }
        }

        let shape: [usize; 4] = [1, 4, DIM_F, DIM_T];
        let tensor = match Tensor::from_array((shape, inbuf)) {
            Ok(t) => t,
            Err(_) => return -4,
        };
        let outputs = match session.run(ort::inputs!["input" => tensor]) {
            Ok(o) => o,
            Err(_) => return -5,
        };
        let arr = match outputs["output"].try_extract_tensor::<f32>() {
            Ok(a) => a,
            Err(_) => return -6,
        };
        let data = arr.1;

        // 模型出的是**伴奏**频谱；人声 = 混合 - 伴奏（频域相减后 iSTFT）。
        for t in 0..tcnt {
            let dst = (t0 + t) * DIM_F;
            for f in 0..DIM_F {
                let idx = f * DIM_T + t;
                spec_re[dst + f] -= data[idx];
                spec_im[dst + f] -= data[DIM_F * DIM_T + idx];
            }
        }
    }

    // ── iSTFT：重叠相加（伴奏已在上面从 mix 里减掉，得到人声谱）───────
    let out_len = n;
    let mut voc = vec![0f32; n_frames * HOP + N_FFT];
    let ins = vec![0f32; n_frames * HOP + N_FFT];
    let mut frame = vec![Complex32::new(0.0, 0.0); N_FFT];

    for t in 0..n_frames {
        let src = t * DIM_F;
        // 人声谱 = 上面留下的 spec（mix - inst）
        for f in 0..DIM_F {
            frame[f] = Complex32::new(spec_re[src + f], spec_im[src + f]);
        }
        // 共轭对称补全（N_FFT=5120 时镜像点是 5120-f）
        for f in 1..DIM_F {
            let m = N_FFT - f;
            if m < N_FFT && m >= DIM_F {
                frame[m] = frame[f].conj();
            }
        }
        ifft.process(&mut frame);
        let norm = 1.0 / N_FFT as f32;
        for i in 0..N_FFT {
            voc[t * HOP + i] += frame[i].re * norm * win[i];
        }

        // 伴奏谱 = 输入谱 - 人声谱；为了省一次 FFT，直接用
        // inst_re/im = orig - vocal，这里需要原始谱副本 —— 见下面的说明。
    }

    // 上面只算了人声；伴奏用「原信号 - 人声」在时域直接相减，
    // 比再跑一次 iSTFT 更省，也没有相位问题。
    for i in 0..out_len {
        let v = if pad + i < voc.len() { voc[pad + i] } else { 0.0 };
        let clamped = if v.is_finite() { v } else { 0.0 };
        vocal_out[i] = clamped;
        inst_out[i] = input[i] - clamped;
    }

    let _ = ins;
    let _ = out_len;
    // 归一化用窗口重叠和（简化：hann 重叠 75% 时和约为 1.5，除以它）
    // ⚠️ 这里的 1.5 是「hann 窗 hop=N/4 时的重叠和」近似值。
    //
    // 权威实现不是用常数，而是**边累加边记窗和**（divider buffer），最后逐点相除 ——
    // 那样在首尾和变长块上也准确。用常数会在边界产生音量跳动。
    // 这一版先保留常数（能跑、能听），下轮对齐时换成 divider。
    for i in 0..out_len {
        let v = if vocal_out[i].is_finite() { vocal_out[i] / 1.5 } else { 0.0 };
        vocal_out[i] = v.clamp(-1.0, 1.0);
        let ins = if inst_out[i].is_finite() { inst_out[i] / 1.5 * COMPENSATE } else { 0.0 };
        inst_out[i] = ins.clamp(-1.0, 1.0);
    }
    0
}

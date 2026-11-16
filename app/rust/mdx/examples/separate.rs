// 桌面验证：用 Linux 的 libonnxruntime.so 跑一遍真实模型，
// 确认 Rust 侧的 STFT/推理/iSTFT 管线不崩、输出有能量分布。
use std::ffi::CString;
use std::os::raw::c_char;

fn read_wav(path: &str) -> (Vec<f32>, u32) {
    let b = std::fs::read(path).expect("读 wav");
    let mut i = 12usize;
    let (mut fmt, mut data_off, mut data_len) = (0usize, 0usize, 0usize);
    while i + 8 <= b.len() {
        let id = String::from_utf8_lossy(&b[i..i + 4]).to_string();
        let size = u32::from_le_bytes([b[i + 4], b[i + 5], b[i + 6], b[i + 7]]) as usize;
        if id == "fmt " { fmt = i + 8; }
        if id == "data" { data_off = i + 8; data_len = size; break; }
        i += 8 + size + (size & 1);
    }
    let ch = u16::from_le_bytes([b[fmt + 2], b[fmt + 3]]) as usize;
    let sr = u32::from_le_bytes([b[fmt + 4], b[fmt + 5], b[fmt + 6], b[fmt + 7]]);
    let n = data_len / 2;
    let mut out = Vec::with_capacity(n / ch.max(1));
    for k in 0..n {
        let off = data_off + k * 2;
        if off + 1 >= b.len() { break; }
        let v = i16::from_le_bytes([b[off], b[off + 1]]) as f32 / 32768.0;
        if k % ch == 0 { out.push(v); }
    }
    (out, sr)
}

fn write_wav(path: &str, s: &[f32], sr: u32) {
    let n = s.len();
    let dl = n * 2;
    let mut b = vec![0u8; 44 + dl];
    b[0..4].copy_from_slice(b"RIFF");
    b[4..8].copy_from_slice(&((36 + dl) as u32).to_le_bytes());
    b[8..12].copy_from_slice(b"WAVE");
    b[12..16].copy_from_slice(b"fmt ");
    b[16..20].copy_from_slice(&16u32.to_le_bytes());
    b[20..22].copy_from_slice(&1u16.to_le_bytes());
    b[22..24].copy_from_slice(&1u16.to_le_bytes());
    b[24..28].copy_from_slice(&sr.to_le_bytes());
    b[28..32].copy_from_slice(&(sr * 2).to_le_bytes());
    b[32..34].copy_from_slice(&2u16.to_le_bytes());
    b[34..36].copy_from_slice(&16u16.to_le_bytes());
    b[36..40].copy_from_slice(b"data");
    b[40..44].copy_from_slice(&(dl as u32).to_le_bytes());
    for i in 0..n {
        let v = (s[i].clamp(-1.0, 1.0) * 32767.0) as i16;
        b[44 + i * 2..46 + i * 2].copy_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, b).expect("写 wav");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (wav_in, model) = (&args[1], &args[2]);
    let (samples, sr) = read_wav(wav_in);
    println!("输入 {} 个采样 / {} Hz / {:.1} 秒", samples.len(), sr, samples.len() as f32 / sr as f32);

    unsafe {
        let mp = CString::new(model.as_str()).unwrap();
        let ort = std::env::var("MDX_ORT_DYLIB").unwrap_or_default();
        let op = CString::new(ort.clone()).unwrap();
        let rc = mdx::mdx_open(mp.as_ptr() as *const c_char, op.as_ptr() as *const c_char);
        println!("mdx_open -> {}", rc);
        if rc != 0 { std::process::exit(1); }

        let n = samples.len();
        let mut voc = vec![0f32; n];
        let mut ins = vec![0f32; n];
        let t0 = std::time::Instant::now();
        let rc2 = mdx::mdx_separate(
            samples.as_ptr(), n, voc.as_mut_ptr(), ins.as_mut_ptr());
        println!("mdx_separate -> {} / 耗时 {:?}", rc2, t0.elapsed());
        mdx::mdx_close();
        if rc2 != 0 { std::process::exit(2); }

        let rms = |v: &[f32]| (v.iter().map(|x| x * x).sum::<f32>() / v.len().max(1) as f32).sqrt();
        println!("原音频 RMS {:.4} / 人声 RMS {:.4} / 伴奏 RMS {:.4}",
            rms(&samples), rms(&voc), rms(&ins));
        write_wav("/tmp/out_vocals.wav", &voc, sr);
        write_wav("/tmp/out_inst.wav", &ins, sr);
        println!("写出 /tmp/out_vocals.wav 与 /tmp/out_inst.wav");
    }
}

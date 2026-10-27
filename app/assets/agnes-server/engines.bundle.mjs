import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, extname, join, resolve, sep } from "node:path";
import { execFile, spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import { inflateRawSync } from "node:zlib";
//#region server/engines/ffmpeg.ts
/**
* ffmpeg 能力层（Host 端）—— 短剧拼接与口播合成都依赖它。
*
* 设计要点（全部经真实调用验证过）：
*  - ffmpeg 可能不在 PATH（用户机器常见），所以定位是多级回退 + 可缓存。
*  - 每次探测都返回结构化结果，绝不 throw 到调用方之外：缺 ffmpeg 时前端要能
*    看到"缺什么、怎么装"，而不是一个空白错误。
*  - 中文字幕需要 CJK 字体；只装了 DejaVu 的机器会把汉字烧成豆腐块，
*    所以字体是"探测 + 明确报错"，不静默退化。
*/
/**
* 数据根目录。
*
* 网页版改造：支持 `AGNES_DATA_DIR` 环境变量，用于挂载卷做持久化。
* 原版只写系统临时目录 —— 插件跑在 DSH 进程里无所谓，但容器一重启，
* 短剧素材、任务记录、本地文件就全丢了。未设置时保持原行为。
*/
function dataRoot() {
	const dir = process.env.AGNES_DATA_DIR || join(tmpdir(), "dsh-agnes-studio");
	try {
		mkdirSync(dir, { recursive: true });
	} catch {}
	return dir;
}
/** Directory for one drama task's media. */
function dramaDir(id) {
	const dir = join(dataRoot(), "dramas", id);
	try {
		mkdirSync(dir, { recursive: true });
	} catch {}
	return dir;
}
/** Directory for one talking-avatar job's media. */
function anchorDir(id) {
	const dir = join(dataRoot(), "anchors", id);
	try {
		mkdirSync(dir, { recursive: true });
	} catch {}
	return dir;
}
const FFMPEG_CANDIDATES = [
	"/usr/bin/ffmpeg",
	"/usr/local/bin/ffmpeg",
	"/opt/homebrew/bin/ffmpeg",
	"C:\\ffmpeg\\bin\\ffmpeg.exe"
];
const FFPROBE_CANDIDATES = [
	"/usr/bin/ffprobe",
	"/usr/local/bin/ffprobe",
	"/opt/homebrew/bin/ffprobe",
	"C:\\ffmpeg\\bin\\ffprobe.exe"
];
let cachedFfmpeg = null;
let cachedProbeMissing = false;
/** Run a command, resolving with exit code + captured output. Never rejects. */
function exec(cmd, args, timeoutMs = 6e5) {
	return new Promise((resolve) => {
		let child;
		try {
			child = spawn(cmd, args, { windowsHide: true });
		} catch (e) {
			resolve({
				code: -1,
				stdout: "",
				stderr: "",
				error: e instanceof Error ? e.message : String(e)
			});
			return;
		}
		let stdout = "";
		let stderr = "";
		let done = false;
		const finish = (r) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			resolve(r);
		};
		const timer = setTimeout(() => {
			try {
				child.kill("SIGKILL");
			} catch {}
			finish({
				code: -1,
				stdout,
				stderr,
				error: `命令超时（${Math.round(timeoutMs / 1e3)}s）`
			});
		}, timeoutMs);
		child.stdout?.on("data", (d) => {
			stdout += String(d);
		});
		child.stderr?.on("data", (d) => {
			stderr += String(d);
		});
		child.on("error", (e) => finish({
			code: -1,
			stdout,
			stderr,
			error: e.message
		}));
		child.on("close", (code) => finish({
			code: code ?? -1,
			stdout,
			stderr
		}));
	});
}
/**
* Locate a usable ffmpeg.
* Order: AGNES_FFMPEG env → PATH (`ffmpeg -version`) → common install paths.
*/
async function resolveFfmpeg() {
	if (cachedFfmpeg) return cachedFfmpeg;
	const fromEnv = process.env.AGNES_FFMPEG;
	const candidates = [];
	if (fromEnv) candidates.push(fromEnv);
	candidates.push("ffmpeg");
	for (const c of FFMPEG_CANDIDATES) if (!candidates.includes(c)) candidates.push(c);
	for (const cmd of candidates) {
		if (cmd.includes("/") || cmd.includes("\\")) {
			if (!existsSync(cmd)) continue;
		}
		const r = await exec(cmd, ["-version"], 15e3);
		if (r.code === 0 && /ffmpeg version/i.test(r.stdout + r.stderr)) {
			cachedFfmpeg = {
				path: cmd,
				version: (r.stdout + r.stderr).split("\n")[0].trim()
			};
			return cachedFfmpeg;
		}
	}
	return null;
}
/** Locate ffprobe (for duration/dimension probing). Returns '' when absent. */
let cachedFfprobe = null;
async function resolveFfprobe() {
	if (cachedFfprobe !== null) return cachedFfprobe;
	if (cachedProbeMissing) return "";
	const fromEnv = process.env.AGNES_FFPROBE;
	const candidates = [];
	if (fromEnv) candidates.push(fromEnv);
	candidates.push("ffprobe");
	for (const c of FFPROBE_CANDIDATES) if (!candidates.includes(c)) candidates.push(c);
	for (const cmd of candidates) {
		if (cmd.includes("/") || cmd.includes("\\")) {
			if (!existsSync(cmd)) continue;
		}
		const r = await exec(cmd, ["-version"], 1e4);
		if (r.code === 0 && /ffprobe version/i.test(r.stdout + r.stderr)) {
			cachedFfprobe = cmd;
			return cmd;
		}
	}
	cachedProbeMissing = true;
	return "";
}
/** Capability report for the UI / smoke tests. */
async function ffmpegStatus() {
	const ff = await resolveFfmpeg();
	const probe = await resolveFfprobe();
	const font = findCjkFont();
	return {
		available: ff !== null,
		path: ff?.path ?? "",
		version: ff?.version ?? "",
		ffprobe: probe !== "",
		font,
		hint: ff ? font ? "" : "未找到中文字体；烧字幕会显示成方块。请安装中文字体（如 fonts-wqy-zenhei / 思源黑体）。" : "未找到 ffmpeg。Linux: apt-get install -y ffmpeg；macOS: brew install ffmpeg；Windows: 安装 ffmpeg 并加入 PATH，或设置 AGNES_FFMPEG 指向 ffmpeg.exe。"
	};
}
const CJK_FONT_CANDIDATES = [
	"/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
	"/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
	"/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/arphic/uming.ttc",
	"/System/Library/Fonts/PingFang.ttc",
	"/System/Library/Fonts/Hiragino Sans GB.ttc",
	"/Library/Fonts/Arial Unicode.ttf",
	"C:\\Windows\\Fonts\\msyh.ttc",
	"C:\\Windows\\Fonts\\msyh.ttf",
	"C:\\Windows\\Fonts\\simhei.ttf",
	"C:\\Windows\\Fonts\\simsun.ttc"
];
let cachedFont = null;
/**
* Find a font file that can render Chinese.
* Returns '' when none is present — callers must surface that instead of
* burning tofu boxes into the output video.
*/
function findCjkFont() {
	if (cachedFont !== null) return cachedFont;
	const fromEnv = process.env.AGNES_SUBTITLE_FONT;
	if (fromEnv && existsSync(fromEnv)) {
		cachedFont = fromEnv;
		return cachedFont;
	}
	for (const f of CJK_FONT_CANDIDATES) if (existsSync(f)) {
		cachedFont = f;
		return cachedFont;
	}
	return "";
}
/** libass `force_style` FontName that matches the discovered font file. */
function fontFamilyFor(file) {
	const lower = file.toLowerCase();
	if (lower.includes("wqy-zenhei")) return "WenQuanYi Zen Hei";
	if (lower.includes("wqy-microhei")) return "WenQuanYi Micro Hei";
	if (lower.includes("pingfang")) return "PingFang SC";
	if (lower.includes("hiragino")) return "Hiragino Sans GB";
	if (lower.includes("msyh")) return "Microsoft YaHei";
	if (lower.includes("simhei")) return "SimHei";
	if (lower.includes("simsun")) return "SimSun";
	if (lower.includes("noto")) return "Noto Sans CJK SC";
	return "sans-serif";
}
/** Probe a media file (duration seconds, dimensions, codec identity). */
async function probeMedia(file) {
	const probe = await resolveFfprobe();
	const empty = {
		ok: false,
		duration: 0,
		width: 0,
		height: 0,
		hasAudio: false,
		videoCodec: "",
		audioCodec: "",
		pixFmt: "",
		fps: 0
	};
	if (!probe) return {
		...empty,
		error: "ffprobe 不可用"
	};
	const r = await exec(probe, [
		"-v",
		"error",
		"-show_entries",
		"format=duration:stream=codec_type,codec_name,width,height,pix_fmt,r_frame_rate",
		"-of",
		"json",
		file
	], 6e4);
	if (r.code !== 0) return {
		...empty,
		error: r.stderr.slice(0, 300)
	};
	try {
		const d = JSON.parse(r.stdout);
		const streams = d.streams ?? [];
		const v = streams.find((s) => s.codec_type === "video");
		const a = streams.find((s) => s.codec_type === "audio");
		let fps = 0;
		const rate = v?.r_frame_rate ?? "";
		if (rate.includes("/")) {
			const [n, den] = rate.split("/").map(Number);
			if (den) fps = n / den;
		}
		return {
			ok: true,
			duration: Number(d.format?.duration ?? 0),
			width: v?.width ?? 0,
			height: v?.height ?? 0,
			hasAudio: a !== void 0,
			videoCodec: v?.codec_name ?? "",
			audioCodec: a?.codec_name ?? "",
			pixFmt: v?.pix_fmt ?? "",
			fps: Number.isFinite(fps) ? Math.round(fps * 100) / 100 : 0
		};
	} catch (e) {
		return {
			...empty,
			error: String(e)
		};
	}
}
/** Run an ffmpeg command with the located binary. */
async function ffmpeg$1(args, timeoutMs = 18e5) {
	const ff = await resolveFfmpeg();
	if (!ff) return {
		ok: false,
		error: "未找到 ffmpeg",
		output: "",
		stderr: ""
	};
	const r = await exec(ff.path, [
		"-hide_banner",
		"-y",
		...args
	], timeoutMs);
	if (r.code !== 0) return {
		ok: false,
		error: (r.error || r.stderr.split("\n").filter(Boolean).slice(-3).join(" | ")).slice(0, 500),
		output: r.stdout,
		stderr: r.stderr
	};
	return {
		ok: true,
		output: r.stdout,
		stderr: r.stderr
	};
}
/** Format seconds as SRT timestamp (HH:MM:SS,mmm). */
function srtTime(sec) {
	const s = Math.max(0, sec);
	const hh = Math.floor(s / 3600);
	const mm = Math.floor(s % 3600 / 60);
	const ss = Math.floor(s % 60);
	const ms = Math.round((s - Math.floor(s)) * 1e3);
	return `${String(hh).padStart(2, "0")}:${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")},${String(ms).padStart(3, "0")}`;
}
/** Build SRT text from cues. */
function buildSrt(cues) {
	return cues.filter((c) => String(c.text ?? "").trim() !== "").map((c, i) => `${i + 1}\n${srtTime(c.start)} --> ${srtTime(c.end)}\n${String(c.text).trim()}\n`).join("\n");
}
/** ASS timestamp: H:MM:SS.cc */
function assTime(sec) {
	const s = Math.max(0, sec);
	const hh = Math.floor(s / 3600);
	const mm = Math.floor(s % 3600 / 60);
	const ss = Math.floor(s % 60);
	const cs = Math.round((s - Math.floor(s)) * 100);
	return `${hh}:${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}.${String(Math.min(99, cs)).padStart(2, "0")}`;
}
/** Neutralise characters ASS would interpret as markup. */
/**
* Approximate advance width of one character, in em units.
* CJK/full-width glyphs are ~1em; Latin/digits ~0.55em; space ~0.3em.
*/
function charWidth(ch) {
	const c = ch.codePointAt(0) ?? 0;
	if (c >= 4352 && c <= 4447 || c === 9001 || c === 9002 || c >= 11904 && c <= 42191 && c !== 12351 || c >= 44032 && c <= 55203 || c >= 63744 && c <= 64255 || c >= 65072 && c <= 65135 || c >= 65280 && c <= 65376 || c >= 65504 && c <= 65510) return 1;
	if (c === 32 || c === 12288) return .3;
	return .55;
}
/**
* Break a cue into lines that fit `maxUnits` em-widths.
*
* libass did NOT wrap space-less Chinese even with WrapStyle 0 — a 41-char cue
* rendered straight across the frame and got clipped at both edges — so the
* line breaks are inserted here instead of being delegated to the renderer.
* Returns text with real newlines; escapeAssText turns them into \N.
*/
function wrapForAss(text, maxUnits) {
	const lines = [];
	for (const para of String(text ?? "").split(/\r?\n/)) {
		if (para === "") {
			lines.push("");
			continue;
		}
		let line = "";
		let w = 0;
		for (const ch of Array.from(para)) {
			const cw = charWidth(ch);
			if (w + cw > maxUnits && line !== "") {
				lines.push(line);
				line = "";
				w = 0;
			}
			line += ch;
			w += cw;
		}
		if (line !== "") lines.push(line);
	}
	return lines.join("\n");
}
function escapeAssText(t) {
	return String(t).replace(/\\/g, "\\\\").replace(/\{/g, "(").replace(/\}/g, ")").replace(/\r?\n/g, "\\N").trim();
}
/**
* Build an ASS subtitle script with an explicit resolution.
*
* Why ASS and not SRT: when libass is handed a bare SRT it assumes a 288-line
* script resolution, so FontSize/MarginV are multiplied by (videoHeight / 288)
* — at 720p a "24px" subtitle actually rendered ~60px tall and sat far too high.
* Declaring PlayResX/PlayResY makes those values true pixels.
*/
function buildAss(cues, opts) {
	const { width, height, fontName } = opts;
	const fontSize = opts.fontSize ?? Math.max(18, Math.round(height * .058));
	const marginV = opts.marginV ?? Math.max(18, Math.round(height * .055));
	const outline = Math.max(1, Math.round(height * .004));
	const header = [
		"[Script Info]",
		"ScriptType: v4.00+",
		`PlayResX: ${width}`,
		`PlayResY: ${height}`,
		"WrapStyle: 0",
		"ScaledBorderAndShadow: yes",
		"YCbCr Matrix: None",
		"",
		"[V4+ Styles]",
		"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
		`Style: Default,${fontName},${fontSize},&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,${outline},0,2,40,40,${marginV},1`,
		"",
		"[Events]",
		"Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
	].join("\n");
	const usable = Math.max(200, width - 80);
	const maxUnits = Math.max(8, Math.floor(usable / fontSize));
	return `${header}\n${cues.filter((c) => String(c.text ?? "").trim() !== "").map((c) => `Dialogue: 0,${assTime(c.start)},${assTime(c.end)},Default,,0,0,0,,${escapeAssText(wrapForAss(c.text, maxUnits))}`).join("\n")}\n`;
}
/**
* Escape a path for use inside an ffmpeg filter argument.
* Colons and backslashes are filter syntax, so Windows paths need care.
*/
function escapeFilterPath(p) {
	return p.replace(/\\/g, "/").replace(/:/g, "\\:").replace(/'/g, "\\'");
}
/**
* Burn subtitles into a video.
*
* `cues` are written to a real .ass file next to the output (libass reads it
* from disk), sized against the input's actual resolution.
*/
async function burnSubtitles(input, cues, output, opts = {}) {
	const font = findCjkFont();
	if (!font) return {
		ok: false,
		error: "缺少中文字体，无法烧录字幕（请安装中文字体或设置 AGNES_SUBTITLE_FONT）",
		output: "",
		stderr: ""
	};
	const probe = await probeMedia(input);
	const width = probe.width || 1280;
	const height = probe.height || 720;
	const assPath = output.replace(/\.[^.]+$/, "") + ".ass";
	try {
		writeFileSync(assPath, buildAss(cues, {
			width,
			height,
			fontName: fontFamilyFor(font),
			fontSize: opts.fontSize,
			marginV: opts.marginV
		}), "utf8");
	} catch (e) {
		return {
			ok: false,
			error: `无法写入字幕文件：${String(e)}`,
			output: "",
			stderr: ""
		};
	}
	return ffmpeg$1([
		"-i",
		input,
		"-vf",
		`subtitles=${escapeFilterPath(assPath)}`,
		"-c:a",
		"copy",
		output
	]);
}
/**
* Concatenate videos in order.
*
* `-c copy` is lossless and fast, but requires identical codec parameters;
* mixing resolutions/framerates produces a broken file. So we probe first and
* re-encode only when the inputs actually differ.
*/
async function concatVideos(files, output, opts = {}) {
	if (files.length === 0) return {
		ok: false,
		error: "没有可拼接的视频",
		output: "",
		stderr: ""
	};
	if (files.length === 1) return {
		...await ffmpeg$1([
			"-i",
			files[0],
			"-c",
			"copy",
			output
		]),
		mode: "copy"
	};
	let probes = await Promise.all(files.map((f) => probeMedia(f)));
	if (probes.some((p) => !p.ok)) return {
		ok: false,
		error: "无法探测输入视频（ffprobe 失败）",
		output: "",
		stderr: ""
	};
	let mode = opts.reencode ? "reencode" : "copy";
	const first = probes[0];
	const uniform = probes.every((p) => p.width === first.width && p.height === first.height && p.videoCodec === first.videoCodec && p.pixFmt === first.pixFmt && Math.abs(p.fps - first.fps) < .01 && p.hasAudio === first.hasAudio && (!first.hasAudio || p.audioCodec === first.audioCodec));
	if (!opts.reencode && !uniform) {
		mode = "reencode";
		opts.onProgress?.("检测到镜头参数不一致，正在逐个归一化后拼接（较慢）");
	}
	const listPath = join(dirname(output), `concat-${Date.now()}.txt`);
	const tempFiles = [];
	try {
		let inputs = files;
		if (mode === "reencode") {
			const target = {
				width: first.width || 1280,
				height: first.height || 720,
				fps: first.fps > 0 && first.fps <= 60 ? first.fps : 25
			};
			inputs = [];
			for (const [i, file] of files.entries()) {
				const norm = join(dirname(output), `norm-${Date.now()}-${i}.mp4`);
				const res = await normalizeClip(file, norm, target);
				if (!res.ok) return {
					ok: false,
					error: `镜头 ${i + 1} 归一化失败：${res.error}`,
					output: "",
					stderr: ""
				};
				tempFiles.push(norm);
				inputs.push(norm);
			}
			probes = await Promise.all(inputs.map((f) => probeMedia(f)));
		}
		writeFileSync(listPath, inputs.map((f) => `file '${f.replace(/'/g, "'\\''")}'`).join("\n") + "\n", "utf8");
		return {
			...await ffmpeg$1([
				"-f",
				"concat",
				"-safe",
				"0",
				"-i",
				listPath,
				"-c",
				"copy",
				output
			]),
			mode
		};
	} finally {
		try {
			rmSync(listPath, { force: true });
		} catch {}
		for (const f of tempFiles) try {
			rmSync(f, { force: true });
		} catch {}
	}
}
/**
* Re-encode one clip to a fixed spec (size, fps, h264/yuv420p, aac stereo).
* Missing audio is filled with silence so every clip has the same streams —
* required for a lossless concat afterwards.
*/
async function normalizeClip(input, output, spec) {
	const probe = await probeMedia(input);
	const videoFilter = `scale=${spec.width}:${spec.height}:force_original_aspect_ratio=decrease,pad=${spec.width}:${spec.height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${spec.fps}`;
	const base = ["-i", input];
	if (!probe.hasAudio) base.push("-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100");
	return ffmpeg$1([
		...base,
		"-vf",
		videoFilter,
		"-c:v",
		"libx264",
		"-pix_fmt",
		"yuv420p",
		"-preset",
		"medium",
		"-crf",
		"20",
		"-c:a",
		"aac",
		"-b:a",
		"128k",
		"-ar",
		"44100",
		"-ac",
		"2",
		"-shortest",
		output
	]);
}
/**
* Mux a narration track over visuals, then burn subtitles.
* Used by the talking-avatar pipeline (B).
*/
async function muxNarration(opts) {
	const filters = [];
	if (opts.cues && opts.cues.length > 0) {
		const font = findCjkFont();
		if (!font) return {
			ok: false,
			error: "缺少中文字体，无法烧录字幕",
			output: "",
			stderr: ""
		};
		const probe = await probeMedia(opts.visualInput);
		const assPath = opts.output.replace(/\.[^.]+$/, "") + ".ass";
		try {
			writeFileSync(assPath, buildAss(opts.cues, {
				width: probe.width || 1280,
				height: probe.height || 720,
				fontName: fontFamilyFor(font),
				fontSize: opts.fontSize
			}), "utf8");
		} catch (e) {
			return {
				ok: false,
				error: `无法写入字幕文件：${String(e)}`,
				output: "",
				stderr: ""
			};
		}
		filters.push(`subtitles=${escapeFilterPath(assPath)}`);
	}
	return ffmpeg$1([
		"-i",
		opts.visualInput,
		"-i",
		opts.audioInput,
		...filters.length ? ["-vf", filters.join(",")] : [],
		"-map",
		"0:v:0",
		"-map",
		"1:a:0",
		"-c:v",
		"libx264",
		"-pix_fmt",
		"yuv420p",
		"-preset",
		"medium",
		"-crf",
		"20",
		"-c:a",
		"aac",
		"-b:a",
		"128k",
		"-shortest",
		opts.output
	]);
}
/** Build a still-image slideshow video of `duration` seconds from one image. */
async function imageToVideo(image, output, duration, size = {
	width: 1280,
	height: 720
}) {
	return ffmpeg$1([
		"-loop",
		"1",
		"-t",
		String(Math.max(.5, duration)),
		"-i",
		image,
		"-vf",
		`scale=${size.width}:${size.height}:force_original_aspect_ratio=decrease,pad=${size.width}:${size.height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25`,
		"-c:v",
		"libx264",
		"-pix_fmt",
		"yuv420p",
		"-preset",
		"medium",
		"-crf",
		"20",
		output
	]);
}
/** Concatenate audio files with optional silence gaps between them. */
async function concatAudio(segments, output) {
	if (segments.length === 0) return {
		ok: false,
		error: "没有音频段",
		output: "",
		stderr: ""
	};
	if (segments.length === 1 && !segments[0].silenceAfterMs) return ffmpeg$1([
		"-i",
		segments[0].file,
		"-c",
		"copy",
		output
	]);
	const dir = dirname(output);
	const silenceFiles = [];
	try {
		const inputs = [];
		for (const [i, seg] of segments.entries()) {
			inputs.push(seg.file);
			const gap = seg.silenceAfterMs ?? 0;
			if (gap > 0 && i < segments.length - 1) {
				const sf = join(dir, `sil-${Date.now()}-${i}.wav`);
				if ((await ffmpeg$1([
					"-f",
					"lavfi",
					"-i",
					"anullsrc=r=24000:cl=mono",
					"-t",
					String(gap / 1e3),
					"-c:a",
					"pcm_s16le",
					sf
				])).ok) {
					silenceFiles.push(sf);
					inputs.push(sf);
				}
			}
		}
		const args = [];
		for (const f of inputs) args.push("-i", f);
		const listPath = join(dir, `acat-${Date.now()}.txt`);
		writeFileSync(listPath, inputs.map((f) => `file '${f.replace(/'/g, "'\\''")}'`).join("\n") + "\n", "utf8");
		try {
			return await ffmpeg$1([
				"-f",
				"concat",
				"-safe",
				"0",
				"-i",
				listPath,
				"-c:a",
				"pcm_s16le",
				"-ar",
				"24000",
				"-ac",
				"1",
				output
			]);
		} finally {
			try {
				rmSync(listPath, { force: true });
			} catch {}
		}
	} finally {
		for (const f of silenceFiles) try {
			rmSync(f, { force: true });
		} catch {}
	}
}
//#endregion
//#region server/engines/vendors.ts
/**
* 厂商端点表 —— **唯一来源**。
*
* 这个表原先在 index.ts / drama-engine.ts / prompt-expert-engine.ts 各写了一份，
* 于是同一个笔误被复制了两遍：Qwen 的域名 `aliyuncs` 少打了一个 y（写成 ali+uncs）。
* 表现为「选 Qwen 模型时，提示词专家与短剧引擎都请求失败」。
* 三份表放一起维护，就是为了让这类不一致没有再次发生的机会。
*/
/** 厂商 → OpenAI 兼容端点基址。 */
const VENDOR_BASE_URLS = {
	agnes: "https://api.agnes-ai.cn/v1",
	deepseek: "https://api.deepseek.com/v1",
	qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1",
	doubao: "https://ark.cn-beijing.volces.com/api/v3",
	minimax: "https://api.minimaxi.com/v1",
	mimo: "https://api.xiaomimimo.com/v1",
	zhipu: "https://open.bigmodel.cn/api/paas/v4",
	ollama: "http://localhost:11434/v1"
};
/**
* 模型名前缀 → 厂商。
*
* 光靠厂商 key 当前缀匹配不够：智谱的模型叫 `glm-4-plus`、`cogview-3-flash`，
* 通义的图像/视频模型叫 `wanx-*`，豆包的叫 `seedream-*` / `seedance-*` ——
* 这些名字都不以厂商 key 开头，会被误判成 agnes 而发错端点。
*/
const VENDOR_MODEL_PREFIXES = {
	zhipu: [
		"glm",
		"cogview",
		"cogvideo",
		"charglm"
	],
	deepseek: ["deepseek"],
	qwen: ["qwen", "wanx"],
	doubao: [
		"doubao",
		"seedream",
		"seedance"
	],
	minimax: [
		"minimax",
		"abab",
		"hailuo",
		"t2a"
	],
	mimo: ["mimo"]
};
/**
* 从模型名推断厂商。
* @param model - 模型 id，如 `deepseek-v4-flash`、`ollama:llama3`。
* @returns 厂商键；无法识别时回落 agnes。
*/
function getVendorFromModel(model) {
	if (!model) return "agnes";
	const m = model.toLowerCase();
	if (m.startsWith("ollama:")) return "ollama";
	for (const [vendor, prefixes] of Object.entries(VENDOR_MODEL_PREFIXES)) if (prefixes.some((p) => m.startsWith(p))) return vendor;
	for (const prefix of Object.keys(VENDOR_BASE_URLS)) if (prefix !== "agnes" && m.startsWith(prefix)) return prefix;
	return "agnes";
}
let deviceVendorsCache = null;
/** 读设备厂商表（带缓存；文件不存在返回空表）。 */
function deviceVendors() {
	if (deviceVendorsCache) return deviceVendorsCache;
	const file = (process.env.DSH_MOBILE_MODELS_FILE || "").trim();
	if (!file) return deviceVendorsCache = {};
	try {
		const raw = JSON.parse(readFileSync(file, "utf8"));
		const out = {};
		for (const [id, v] of Object.entries(raw.vendors || {})) {
			if (!v || typeof v.baseUrl !== "string" || !v.baseUrl) continue;
			out[id] = {
				baseUrl: v.baseUrl.replace(/\/+$/, ""),
				...typeof v.apiKey === "string" && v.apiKey ? { apiKey: v.apiKey } : {},
				...Array.isArray(v.models) ? { models: v.models.filter((m) => typeof m === "string" && m) } : {}
			};
		}
		return deviceVendorsCache = out;
	} catch {
		return deviceVendorsCache = {};
	}
}
/** 把设备厂商并进 [VENDOR_BASE_URLS]（内置表优先，不被覆盖）。 */
function mergeDeviceVendors() {
	for (const [id, v] of Object.entries(deviceVendors())) if (!VENDOR_BASE_URLS[id]) VENDOR_BASE_URLS[id] = v.baseUrl;
}
//#endregion
//#region server/engines/drama-engine.ts
/**
* 短剧流水线引擎 — Host 端核心逻辑
* 管理短剧任务的创建、状态、持久化和异步执行。
*/
const dramaTasks = /* @__PURE__ */ new Map();
const runningDramas = /* @__PURE__ */ new Set();
const DRAMA_DIR = join(dataRoot(), "dramas");
function getDramaPath(id) {
	const dir = dramaDir(id);
	return join(dir, "task.json");
}
function saveToDisk$5(task) {
	try {
		writeFileSync(getDramaPath(task.drama_id), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function loadFromDisk$5(id) {
	try {
		const p = getDramaPath(id);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
function updateTask(task, patch) {
	Object.assign(task, patch, { updated_at: Date.now() });
	dramaTasks.set(task.drama_id, task);
	saveToDisk$5(task);
}
const STORY_PROMPT = "你是一位才华横溢的短剧作家。根据用户描述创作一个300～500字的故事梗概。要求：完整起承转合，场景有画面感，包含核心冲突和高潮。直接输出故事正文，不要标题。";
const SCRIPT_PROMPT = "你是专业短剧编剧。将故事1:1精准还原为专业短剧剧本。格式：每场以「编号 日/夜、内/外、场景名」开头，画面用「▲」，旁白用「vo：」。直接输出剧本。";
function storyboardPrompt(dur) {
	return `你是资深分镜师。将剧本转为分镜脚本，每镜约${dur}秒。动作拆分起势→发力→收势，标注运镜和转场。输出JSON：{"shots":[{"shot_index":1,"scene_desc":"画面描述","characters":[],"action":"起势→发力→收势","camera":"景别","camera_movement":{"type":"运镜","intent":"意图"},"dialogue":"","prompt_en":"English prompt","transition":{"type":"转场","description":"说明"}}]}`;
}
const ASSETS_PROMPT = "从剧本和分镜提取角色/场景/道具的视觉特征。输出JSON：{\"characters\":[{\"name\":\"\",\"desc\":\"中文描述\",\"prompt_en\":\"English for three-view\"}],\"scenes\":[{\"name\":\"\",\"desc\":\"\",\"prompt_en\":\"\"}],\"props\":[{\"name\":\"\",\"desc\":\"\",\"prompt_en\":\"\"}]}";
async function callTextModel(sysPrompt, userPrompt, apiKey, model, maxTokens = 4096) {
	const baseUrl = VENDOR_BASE_URLS[getVendorFromModel(model)] || VENDOR_BASE_URLS.agnes;
	const ac = new AbortController();
	const t = setTimeout(() => ac.abort(), 3e5);
	try {
		const r = await fetch(`${baseUrl}/chat/completions`, {
			method: "POST",
			signal: ac.signal,
			headers: {
				"Authorization": `Bearer ${apiKey}`,
				"Content-Type": "application/json"
			},
			body: JSON.stringify({
				model,
				messages: [{
					role: "system",
					content: sysPrompt
				}, {
					role: "user",
					content: userPrompt
				}],
				max_tokens: maxTokens,
				temperature: .7
			})
		});
		if (!r.ok) throw new Error(`API ${r.status}: ${(await r.text()).slice(0, 300)}`);
		return (await r.json()).choices?.[0]?.message?.content || "";
	} finally {
		clearTimeout(t);
	}
}
function parseJson(text) {
	let c = text.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
	if (c.startsWith("```")) {
		const lines = c.split("\n");
		let end = lines.length;
		for (let i = lines.length - 1; i > 0; i--) if (lines[i].trim().startsWith("```")) {
			end = i;
			break;
		}
		c = lines.slice(1, end).join("\n").trim();
	}
	try {
		return JSON.parse(c);
	} catch {}
	const i = c.indexOf("{");
	if (i > 0) try {
		return JSON.parse(c.slice(i));
	} catch {}
	return null;
}
function waitConfirm(task, expected) {
	return new Promise((resolve) => {
		const check = () => {
			if (task.status !== expected || task.status === "stopped" || task.status === "failed") {
				resolve();
				return;
			}
			setTimeout(check, 1e3);
		};
		check();
	});
}
function waitAllVideos(task) {
	return new Promise((resolve) => {
		const check = () => {
			if (task.status === "stopped" || task.status === "failed") {
				resolve();
				return;
			}
			const vr = task.video_results || [];
			if (vr.length > 0 && vr.every((r) => r.status === "completed" || r.status === "failed")) {
				resolve();
				return;
			}
			setTimeout(check, 3e3);
		};
		check();
	});
}
async function runPipeline(task, apiKey, startStep) {
	const model = task.text_model;
	try {
		let scriptText = task.script || "";
		if (startStep === "script" && scriptText) updateTask(task, {
			status: "step2",
			step: "step2",
			message: "已导入剧本，正在生成分镜..."
		});
		else {
			updateTask(task, {
				status: "step1",
				step: "step1",
				message: "正在创作故事梗概..."
			});
			updateTask(task, {
				story: await callTextModel(STORY_PROMPT, `请根据以下描述创作一个300～500字的短剧故事：\n${task.prompt}`, apiKey, model, 4096),
				status: "paused_story",
				message: "故事梗概已生成，请确认"
			});
			await waitConfirm(task, "paused_story");
			if (task.status === "stopped" || task.status === "failed") return;
			updateTask(task, {
				status: "step2",
				message: "正在生成剧本..."
			});
			scriptText = await callTextModel(SCRIPT_PROMPT, `请将以下故事改编为专业短剧剧本：\n${task.edited_story || task.story || ""}`, apiKey, model, 16384);
			updateTask(task, {
				script: scriptText,
				status: "paused_script",
				message: "剧本已生成，请确认"
			});
			await waitConfirm(task, "paused_script");
			if (task.status === "stopped" || task.status === "failed") return;
			scriptText = task.edited_script || task.script || scriptText;
		}
		updateTask(task, {
			status: "step2",
			step: "step2",
			message: "正在生成分镜..."
		});
		const shots = parseJson(await callTextModel(storyboardPrompt(task.shot_duration), `请将以下剧本改写为分镜脚本：\n${task.edited_script || scriptText}`, apiKey, model, 16384))?.shots || [];
		updateTask(task, {
			storyboard: { shots },
			shots,
			status: "step3",
			message: `分镜完成，共 ${shots.length} 个镜头`
		});
		updateTask(task, {
			status: "step3",
			message: "正在提取素材..."
		});
		const aData = parseJson(await callTextModel(ASSETS_PROMPT, `请从以下内容提取角色/场景/道具：\n剧本：${task.script || ""}\n分镜：${JSON.stringify({ shots })}`, apiKey, model, 16384));
		const allAssets = [];
		for (const cat of [
			"characters",
			"scenes",
			"props"
		]) for (const item of aData?.[cat] || []) allAssets.push({
			category: cat,
			name: item.name || "",
			desc: item.desc || "",
			prompt_en: item.prompt_en || "",
			status: "pending"
		});
		updateTask(task, {
			assets: allAssets,
			status: "paused_assets",
			message: `提取到 ${allAssets.length} 个素材，请确认`
		});
		await waitConfirm(task, "paused_assets");
		if (task.status === "stopped" || task.status === "failed") return;
		updateTask(task, {
			video_results: shots.map((s) => ({
				shot_index: s.shot_index,
				status: "pending"
			})),
			status: "paused_video",
			message: "素材已就绪，请逐个启动视频生成"
		});
		await waitAllVideos(task);
		updateTask(task, {
			status: "completed",
			message: "短剧制作完成"
		});
	} catch (e) {
		if (task.status === "stopped") return;
		updateTask(task, {
			status: "failed",
			message: `流水线失败: ${e instanceof Error ? e.message : String(e)}`
		});
	} finally {
		runningDramas.delete(task.drama_id);
	}
}
/** Local file path for one shot's generated video. */
function shotFilePath(dramaId, shotIndex) {
	return join(dramaDir(dramaId), `shot-${shotIndex}.mp4`);
}
/** Build the video prompt for a shot (English prompt preferred). */
function shotPrompt(shot) {
	const parts = [
		shot.prompt_en,
		shot.scene_desc,
		shot.action
	].map((s) => String(s ?? "").trim()).filter(Boolean);
	const camera = String(shot.camera ?? "").trim();
	const move = String(shot.camera_movement?.type ?? "").trim();
	let prompt = parts.join(". ");
	if (camera) prompt += `, ${camera} shot`;
	if (move) prompt += `, camera ${move}`;
	return prompt || "cinematic scene";
}
/** Download a URL to a local file. Returns the byte size. */
async function downloadTo(url, dest, timeoutMs = 3e5) {
	const ac = new AbortController();
	const timer = setTimeout(() => ac.abort(), timeoutMs);
	try {
		const r = await fetch(url, { signal: ac.signal });
		if (!r.ok) throw new Error(`下载失败 HTTP ${r.status}`);
		const buf = Buffer.from(await r.arrayBuffer());
		if (buf.length === 0) throw new Error("下载内容为空");
		writeFileSync(dest, buf);
		return buf.length;
	} finally {
		clearTimeout(timer);
	}
}
/**
* Generate one shot's video for real: submit → poll → download.
*
* Agnes video models are verified end-to-end (submit /v1/videos, poll
* /v1/videos/{id}, download metadata.url). Other vendors have different
* contracts, so we fail loudly rather than silently producing nothing.
*/
async function runShotVideo(task, shotIndex, host) {
	const model = task.video_model || "agnes-video-2.5-flash";
	const vr = (task.video_results || []).find((r) => r.shot_index === shotIndex);
	if (!vr) return;
	const shot = (task.shots || task.storyboard?.shots || []).find((s) => s.shot_index === shotIndex);
	const setVr = (patch) => {
		Object.assign(vr, patch);
		updateTask(task, { video_results: task.video_results });
	};
	setVr({
		status: "generating",
		error: void 0,
		prompt: shot ? shotPrompt(shot) : void 0
	});
	if (!model.toLowerCase().startsWith("agnes-video")) {
		setVr({
			status: "failed",
			error: `当前仅支持 Agnes 视频模型（agnes-video-*）自动生成，收到「${model}」。请在短剧设置中改用 agnes-video-2.5-flash。`
		});
		return;
	}
	try {
		const prompt = shot ? shotPrompt(shot) : "cinematic scene";
		const seconds = String(Math.max(1, Math.round(task.shot_duration || 5)));
		const submitted = await host.call("agnes", "/v1/videos", {
			method: "POST",
			body: {
				model,
				prompt,
				mode: "text",
				seconds,
				size: "720P"
			},
			timeoutMs: 12e4
		});
		const videoId = String(submitted?.video_id || submitted?.id || submitted?.task_id || "");
		if (!videoId) throw new Error("视频接口未返回任务 ID");
		const deadline = Date.now() + 12e5;
		let url = "";
		while (Date.now() < deadline) {
			await new Promise((r) => setTimeout(r, 8e3));
			if (task.status === "stopped") return;
			const st = await host.call("agnes", `/v1/videos/${encodeURIComponent(videoId)}`, {
				method: "GET",
				timeoutMs: 6e4
			});
			const status = String(st?.status ?? "");
			if (status === "completed") {
				url = String(st?.metadata?.url || st?.url || "");
				if (!url) throw new Error("任务完成但未返回视频地址");
				break;
			}
			if (status === "failed") throw new Error(String(st?.error?.message || st?.error || "视频生成失败"));
		}
		if (!url) throw new Error("视频生成超时（20 分钟）");
		const dest = shotFilePath(task.drama_id, shotIndex);
		await downloadTo(url, dest);
		const probe = await probeMedia(dest);
		setVr({
			status: "completed",
			video_url: url,
			error: void 0
		});
		updateTask(task, {
			video_results: task.video_results,
			message: `镜头 ${shotIndex} 完成${probe.ok ? `（${probe.duration.toFixed(1)}s）` : ""}`
		});
	} catch (e) {
		setVr({
			status: "failed",
			error: e instanceof Error ? e.message : String(e)
		});
	}
}
/** Kick off every unfinished shot, sequentially (keeps API quota predictable). */
async function runAllShotVideos(task, host) {
	for (const r of task.video_results || []) {
		if (task.status === "stopped") return;
		if (r.status === "completed") continue;
		await runShotVideo(task, r.shot_index, host);
	}
	const remaining = (task.video_results || []).filter((r) => r.status !== "completed");
	if (remaining.length === 0) updateTask(task, {
		status: "completed",
		message: "全部镜头已完成，可合成成片"
	});
	else updateTask(task, {
		status: "paused_video",
		message: `${remaining.length} 个镜头未成功，可重试或先合成已完成的镜头`
	});
}
/** Collect completed shot files in storyboard order. */
function completedShotFiles(task) {
	const shots = task.shots || task.storyboard?.shots || [];
	const order = shots.length > 0 ? shots.map((s) => s.shot_index) : (task.video_results || []).map((r) => r.shot_index);
	const out = [];
	for (const idx of order) {
		const r = (task.video_results || []).find((v) => v.shot_index === idx);
		if (!r || r.status !== "completed") continue;
		const file = shotFilePath(task.drama_id, idx);
		if (!existsSync(file) || statSync(file).size === 0) continue;
		out.push({
			shotIndex: idx,
			file,
			shot: shots.find((s) => s.shot_index === idx)
		});
	}
	return out;
}
/**
* Merge completed shots into a final cut.
* Subtitles are opt-in and come from each shot's dialogue.
*/
async function mergeDrama(task, opts) {
	const items = completedShotFiles(task);
	if (items.length === 0) return {
		ok: false,
		error: "没有已完成的镜头视频可合成。请先生成至少一个镜头。"
	};
	const ff = await ffmpegStatus();
	if (!ff.available) return {
		ok: false,
		error: ff.hint
	};
	const dir = dramaDir(task.drama_id);
	const outFile = join(dir, "final.mp4");
	updateTask(task, {
		status: "merging",
		message: `正在合成 ${items.length} 个镜头...`
	});
	const res = await concatVideos(items.map((i) => i.file), outFile, { reencode: opts.reencode });
	if (!res.ok) {
		updateTask(task, {
			status: "paused_video",
			message: "合成失败"
		});
		return {
			ok: false,
			error: res.error
		};
	}
	if (opts.subtitles) {
		if (!ff.font) {
			updateTask(task, {
				status: "paused_video",
				message: "缺中文字体，未烧字幕"
			});
			return {
				ok: false,
				error: `缺少中文字体，无法烧录字幕。${ff.hint}`
			};
		}
		const cues = [];
		let cursor = 0;
		for (const it of items) {
			const probe = await probeMedia(it.file);
			const dur = probe.ok ? probe.duration : 0;
			const text = String(it.shot?.dialogue ?? "").trim();
			if (text) cues.push({
				start: cursor + .2,
				end: Math.max(cursor + 1.2, cursor + dur - .2),
				text
			});
			cursor += dur;
		}
		if (cues.length > 0) {
			const srtPath = join(dir, "final.srt");
			writeFileSync(srtPath, buildSrt(cues), "utf8");
			const subOut = join(dir, "final-subbed.mp4");
			const burned = await burnSubtitles(outFile, cues, subOut);
			if (!burned.ok) {
				updateTask(task, {
					status: "paused_video",
					message: "字幕烧录失败"
				});
				return {
					ok: false,
					error: `字幕烧录失败：${burned.error}`
				};
			}
			const probe = await probeMedia(subOut);
			updateTask(task, {
				status: "completed",
				message: `成片已生成（含字幕，${items.length} 镜）`
			});
			return {
				ok: true,
				file: subOut,
				duration: probe.duration,
				mode: res.mode,
				shots: items.length
			};
		}
	}
	const probe = await probeMedia(outFile);
	updateTask(task, {
		status: "completed",
		message: `成片已生成（${items.length} 镜）`
	});
	return {
		ok: true,
		file: outFile,
		duration: probe.duration,
		mode: res.mode,
		shots: items.length
	};
}
/** Restrict a media request to files inside a drama's own directory. */
function resolveDramaMedia(dramaId, filename) {
	if (!dramaId || !filename) return null;
	const dir = resolve(dramaDir(dramaId));
	const candidate = resolve(dir, basename(filename));
	if (!candidate.startsWith(dir + "/") && !candidate.startsWith(dir + "\\")) return null;
	return existsSync(candidate) && statSync(candidate).isFile() ? candidate : null;
}
async function handleDramaRoute(method, urlPath, body, host) {
	const dp = urlPath.replace(/^\/agnes-studio\/api\/?/, "").replace(/^drama\/?/, "");
	const resolveApiKey = (v) => host.resolveKey(v);
	if (method === "POST" && dp === "start") {
		const id = randomUUID().slice(0, 12);
		const task = {
			drama_id: id,
			prompt: body.prompt || "",
			status: "started",
			step: "",
			message: "正在启动...",
			text_model: body.text_model || "agnes-3.0-flash",
			image_model: body.image_model || "agnes-image-2.5-flash",
			video_model: body.video_model || "agnes-video-2.5-flash",
			shot_duration: body.shot_duration || 5,
			created_at: Date.now(),
			updated_at: Date.now()
		};
		dramaTasks.set(id, task);
		saveToDisk$5(task);
		resolveApiKey(getVendorFromModel(task.text_model)).then((k) => {
			runningDramas.add(id);
			runPipeline(task, k);
		}).catch((e) => updateTask(task, {
			status: "failed",
			message: `API Key 获取失败: ${e}`
		}));
		return {
			status: 200,
			data: {
				drama_id: id,
				status: "started"
			}
		};
	}
	if (method === "POST" && dp === "import") {
		const id = randomUUID().slice(0, 12);
		const scriptContent = body.script || "";
		if (!scriptContent.trim()) return {
			status: 400,
			data: { error: "剧本内容为空" }
		};
		const task = {
			drama_id: id,
			prompt: body.prompt || scriptContent.slice(0, 100),
			status: "started",
			step: "",
			message: "正在从导入的剧本生成分镜...",
			script: scriptContent,
			text_model: body.text_model || "agnes-3.0-flash",
			image_model: body.image_model || "agnes-image-2.5-flash",
			video_model: body.video_model || "agnes-video-2.5-flash",
			shot_duration: body.shot_duration || 5,
			created_at: Date.now(),
			updated_at: Date.now()
		};
		dramaTasks.set(id, task);
		saveToDisk$5(task);
		resolveApiKey(getVendorFromModel(task.text_model)).then((k) => {
			runningDramas.add(id);
			runPipeline(task, k, "script");
		}).catch((e) => updateTask(task, {
			status: "failed",
			message: `API Key 获取失败: ${e}`
		}));
		return {
			status: 200,
			data: {
				drama_id: id,
				status: "started"
			}
		};
	}
	if (method === "GET" && dp === "list") return {
		status: 200,
		data: { tasks: Array.from(dramaTasks.values()).slice(0, 20) }
	};
	const statusMatch = /^status\/(.+)$/.exec(dp);
	if (method === "GET" && statusMatch) {
		const statusId = statusMatch[1];
		const statusTask = dramaTasks.get(statusId) || loadFromDisk$5(statusId);
		if (!statusTask) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		return {
			status: 200,
			data: {
				...statusTask,
				completed: (statusTask.video_results || []).filter((r) => r.status === "completed").length,
				final: existsSync(join(dramaDir(statusTask.drama_id), "final.mp4"))
			}
		};
	}
	const parts = dp.split("/");
	const id = parts[0];
	if (!id) return null;
	let task = dramaTasks.get(id) || loadFromDisk$5(id);
	if (!task) return {
		status: 404,
		data: { error: "任务不存在" }
	};
	if (method === "GET" && parts.length === 1) return {
		status: 200,
		data: task
	};
	if (method === "POST" && parts[1] === "stop") {
		updateTask(task, {
			status: "stopped",
			message: "已停止"
		});
		runningDramas.delete(id);
		return {
			status: 200,
			data: { ok: true }
		};
	}
	if (method === "POST" && parts[1] === "resume") {
		if (!runningDramas.has(id) && task.status !== "failed" && task.status !== "completed") {
			runningDramas.add(id);
			resolveApiKey(getVendorFromModel(task.text_model)).then((k) => runPipeline(task, k));
		}
		return {
			status: 200,
			data: { ok: true }
		};
	}
	if (method === "POST" && parts[1] === "confirm") {
		const { field, content, action, shot_index } = body;
		if (field === "story" && content) updateTask(task, {
			edited_story: content,
			story: content
		});
		else if (field === "script" && content) updateTask(task, {
			edited_script: content,
			script: content
		});
		else if (field === "assets" && action === "approve") {
			if (task.status === "paused_assets") updateTask(task, {
				status: "step4",
				message: "素材已确认，准备生成视频..."
			});
		} else if (field === "video") {
			if (shot_index !== void 0) {
				const vr = (task.video_results || []).find((r) => r.shot_index === shot_index);
				if (vr) {
					vr.status = "generating";
					vr.error = void 0;
					updateTask(task, {
						video_results: task.video_results,
						message: `镜头 ${shot_index} 生成中...`
					});
					runShotVideo(task, shot_index, host);
				}
			} else if (action === "complete") {
				const pending = (task.video_results || []).filter((r) => r.status !== "completed");
				if (pending.length > 0) return {
					status: 400,
					data: { error: `还有 ${pending.length} 个镜头未完成，请先生成或等其完成` }
				};
				updateTask(task, {
					status: "completed",
					message: "短剧制作完成"
				});
			}
		}
		return {
			status: 200,
			data: { ok: true }
		};
	}
	if (method === "POST" && parts[1] === "videos") {
		if ((task.video_results || []).length === 0) return {
			status: 400,
			data: { error: "还没有分镜，无法生成视频" }
		};
		updateTask(task, { message: "正在依次生成所有镜头..." });
		runAllShotVideos(task, host);
		return {
			status: 200,
			data: {
				ok: true,
				queued: (task.video_results || []).filter((r) => r.status !== "completed").length
			}
		};
	}
	if (method === "POST" && parts[1] === "merge") {
		const result = await mergeDrama(task, {
			subtitles: body?.subtitles === true,
			reencode: body?.reencode === true
		});
		if (!result.ok) return {
			status: 400,
			data: { error: result.error }
		};
		const file = basename(result.file || "");
		return {
			status: 200,
			data: {
				ok: true,
				shots: result.shots,
				duration: result.duration,
				mode: result.mode,
				file,
				url: `/agnes-studio/api/media/${task.drama_id}/${file}`
			}
		};
	}
	if (method === "GET" && parts[1] === "status") return {
		status: 200,
		data: {
			drama_id: task.drama_id,
			status: task.status,
			message: task.message,
			shots: (task.shots || task.storyboard?.shots || []).length,
			videos: (task.video_results || []).map((r) => ({
				shot_index: r.shot_index,
				status: r.status,
				error: r.error ?? null
			})),
			completed: (task.video_results || []).filter((r) => r.status === "completed").length,
			final: existsSync(join(dramaDir(task.drama_id), "final.mp4"))
		}
	};
	if (method === "POST" && parts[1] === "regenerate") {
		const { step } = body;
		if (step === "story") updateTask(task, {
			story: void 0,
			edited_story: void 0,
			status: "step1"
		});
		else if (step === "script") updateTask(task, {
			script: void 0,
			edited_script: void 0
		});
		return {
			status: 200,
			data: { ok: true }
		};
	}
	return null;
}
function rehydrateDramas() {
	try {
		if (!existsSync(DRAMA_DIR)) return;
		const dirs = readdirSync(DRAMA_DIR);
		let count = 0;
		for (const d of dirs) {
			const t = loadFromDisk$5(d);
			if (!t) continue;
			dramaTasks.set(d, t);
			if ([
				"started",
				"step1",
				"step2",
				"step3",
				"step4"
			].includes(t.status)) {
				updateTask(t, {
					status: "failed",
					message: "进程重启导致中断"
				});
				count++;
			}
		}
		if (count) console.log(`[短剧] 已恢复 ${count} 个历史任务`);
	} catch (e) {
		console.error("[短剧] 恢复失败:", e);
	}
}
//#endregion
//#region server/engines/anchor-engine.ts
/**
* 数字人口播引擎（Host 端）—— 文稿 → 分段 → TTS 配音 → 画面 → 字幕 → 合成。
*
* 真实验证过的依赖：
*  - MiMo TTS（mimo-v2.5-tts，POST /chat/completions，返回 base64 wav）——已实测
*  - ffmpeg（拼接 / 字幕烧录 / 音画合成）——已实测
*  - 中文 CJK 字体 —— 缺失时明确报错，绝不静默出豆腐块
*
* 画面三种模式：
*  static  静态形象图：任意图片循环展示（最稳、最快，推荐）
*  clip    视频素材：上传视频循环/裁剪到旁白长度
*  ai      AI 生成画面：用 Agnes 文生视频生成一段背景片，再循环铺满旁白
*/
const anchorTasks = /* @__PURE__ */ new Map();
const runningAnchors = /* @__PURE__ */ new Set();
function taskPath(id) {
	const dir = anchorDir(id);
	return join(dir, "task.json");
}
function save(task) {
	task.updated_at = Date.now();
	anchorTasks.set(task.anchor_id, task);
	try {
		writeFileSync(taskPath(task.anchor_id), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function load(id) {
	try {
		const p = taskPath(id);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
function setStatus(task, status, message) {
	task.status = status;
	task.message = message;
	save(task);
}
/** Rough Chinese speech rate used to estimate how long a segment will take. */
const CHARS_PER_SEC = 4.2;
/**
* Split narration into subtitle-sized segments.
* Splits on sentence punctuation, then merges fragments that are too short and
* splits any segment that is too long — so subtitles stay readable and each
* TTS call stays small.
*/
function segmentText(text, minSegSec) {
	const clean = String(text ?? "").replace(/\r\n/g, "\n").trim();
	if (!clean) return [];
	const rough = clean.split(/(?<=[。！？!?；;])|\n+/).map((s) => s.trim()).filter(Boolean);
	const minChars = Math.max(6, Math.round(minSegSec * CHARS_PER_SEC));
	const maxChars = 60;
	const merged = [];
	for (const piece of rough) {
		const last = merged[merged.length - 1];
		if (last !== void 0 && last.length < minChars && (last + piece).length <= maxChars) merged[merged.length - 1] = last + piece;
		else merged.push(piece);
	}
	const out = [];
	for (const seg of merged) {
		if (seg.length <= maxChars) {
			out.push(seg);
			continue;
		}
		const parts = seg.split(/(?<=[，,、])/).map((s) => s.trim()).filter(Boolean);
		let buf = "";
		for (const p of parts) if ((buf + p).length > maxChars && buf) {
			out.push(buf);
			buf = p;
		} else buf += p;
		if (buf) out.push(buf);
	}
	return out.filter((s) => s.trim() !== "");
}
const MIMO_DEFAULT_URL = "https://api.xiaomimimo.com/v1";
const MIMO_TOKEN_PLAN_URL = "https://token-plan-cn.xiaomimimo.com/v1";
/** MiMo routes Token-Plan keys (`tp-`) to a different cluster base URL. */
function mimoBaseUrl(apiKey) {
	return String(apiKey || "").trim().startsWith("tp-") ? MIMO_TOKEN_PLAN_URL : MIMO_DEFAULT_URL;
}
/** Style instruction that makes the delivery sound like a person, not a robot. */
function ttsStyle(minSegSec) {
	return "自然、清晰、适合中文口播解说。语气有感染力、有起伏，像在给观众讲故事，不要平淡机械。语速中等，节奏稳定。";
}
/**
* Synthesize one segment with MiMo TTS.
* Contract verified against the live API: POST /chat/completions with an
* `audio` block; the WAV comes back base64 in choices[0].message.audio.data.
*/
async function synthesize(text, voice, outFile, apiKey, minSegSec) {
	const url = `${mimoBaseUrl(apiKey)}/chat/completions`;
	const ac = new AbortController();
	const timer = setTimeout(() => ac.abort(), 18e4);
	try {
		const r = await fetch(url, {
			method: "POST",
			signal: ac.signal,
			headers: {
				Authorization: `Bearer ${apiKey}`,
				"Content-Type": "application/json"
			},
			body: JSON.stringify({
				model: "mimo-v2.5-tts",
				messages: [{
					role: "user",
					content: ttsStyle(minSegSec)
				}, {
					role: "assistant",
					content: text
				}],
				audio: {
					format: "wav",
					voice: voice || "mimo_default"
				}
			})
		});
		if (!r.ok) {
			const body = await r.text().catch(() => "");
			if (r.status === 401) return {
				ok: false,
				error: "TTS 认证失败（401）：请检查 MIMO_API_KEY"
			};
			return {
				ok: false,
				error: `TTS 失败 HTTP ${r.status}: ${body.slice(0, 200)}`
			};
		}
		const b64 = (await r.json())?.choices?.[0]?.message?.audio?.data;
		if (typeof b64 !== "string" || b64.length === 0) return {
			ok: false,
			error: "TTS 响应缺少 audio.data"
		};
		writeFileSync(outFile, Buffer.from(b64, "base64"));
		return { ok: true };
	} catch (e) {
		return {
			ok: false,
			error: e instanceof Error ? e.message : String(e)
		};
	} finally {
		clearTimeout(timer);
	}
}
/**
* Materialise a client-supplied image/video into a local file.
* Accepts data URLs (uploaded files) or http(s) URLs (generated assets).
*/
async function materialize$3(input, destWithoutExt) {
	try {
		if (input.kind === "data") {
			const m = /^data:([^;,]+)?(;base64)?,(.*)$/s.exec(input.value);
			if (!m) return {
				ok: false,
				error: "无法解析上传的素材（data URL 格式错误）"
			};
			const mime = m[1] || "application/octet-stream";
			const isB64 = Boolean(m[2]);
			const file = destWithoutExt + (mime.includes("png") ? ".png" : mime.includes("jpeg") || mime.includes("jpg") ? ".jpg" : mime.includes("webp") ? ".webp" : mime.includes("quicktime") || mime.includes("mov") ? ".mov" : mime.includes("webm") ? ".webm" : mime.includes("video/mp4") ? ".mp4" : ".bin");
			const buf = isB64 ? Buffer.from(m[3], "base64") : Buffer.from(decodeURIComponent(m[3]), "binary");
			if (buf.length === 0) return {
				ok: false,
				error: "上传素材为空"
			};
			writeFileSync(file, buf);
			return {
				ok: true,
				file
			};
		}
		const r = await fetch(input.value);
		if (!r.ok) return {
			ok: false,
			error: `下载素材失败 HTTP ${r.status}`
		};
		const buf = Buffer.from(await r.arrayBuffer());
		const lower = input.value.toLowerCase();
		const file = destWithoutExt + (lower.includes(".png") ? ".png" : lower.includes(".jpg") || lower.includes(".jpeg") ? ".jpg" : lower.includes(".webp") ? ".webp" : lower.includes(".mov") ? ".mov" : lower.includes(".webm") ? ".webm" : lower.includes(".mp4") ? ".mp4" : ".bin");
		writeFileSync(file, buf);
		return {
			ok: true,
			file
		};
	} catch (e) {
		return {
			ok: false,
			error: e instanceof Error ? e.message : String(e)
		};
	}
}
/** Generate one background video with Agnes (verified submit → poll → url). */
async function generateAiVisual(prompt, host, seconds = 5) {
	try {
		const submitted = await host.call("agnes", "/v1/videos", {
			method: "POST",
			body: {
				model: "agnes-video-2.5-flash",
				prompt,
				mode: "text",
				seconds: String(seconds),
				size: "720P"
			},
			timeoutMs: 12e4
		});
		const id = String(submitted?.video_id || submitted?.id || "");
		if (!id) return {
			ok: false,
			error: "AI 画面：视频接口未返回任务 ID"
		};
		const deadline = Date.now() + 12e5;
		while (Date.now() < deadline) {
			await new Promise((r) => setTimeout(r, 8e3));
			const st = await host.call("agnes", `/v1/videos/${encodeURIComponent(id)}`, {
				method: "GET",
				timeoutMs: 6e4
			});
			const status = String(st?.status ?? "");
			if (status === "completed") {
				const url = String(st?.metadata?.url || st?.url || "");
				return url ? {
					ok: true,
					url
				} : {
					ok: false,
					error: "AI 画面：完成但无地址"
				};
			}
			if (status === "failed") return {
				ok: false,
				error: `AI 画面生成失败：${st?.error?.message || ""}`
			};
		}
		return {
			ok: false,
			error: "AI 画面生成超时"
		};
	} catch (e) {
		return {
			ok: false,
			error: e instanceof Error ? e.message : String(e)
		};
	}
}
/**
* Run the talking-avatar pipeline.
* Every stage reports progress so the panel can show where it is.
*/
async function runAnchor(task, host) {
	const dir = anchorDir(task.anchor_id);
	try {
		setStatus(task, "tts", "正在合成配音...");
		const apiKey = await host.resolveTtsKey();
		let cursor = 0;
		for (const seg of task.segments) {
			if (task.status === "stopped") return;
			const out = join(dir, `seg-${seg.index}.wav`);
			const r = await synthesize(seg.text, task.voice, out, apiKey, task.min_seg_sec);
			if (!r.ok) {
				seg.status = "failed";
				seg.error = r.error;
				save(task);
				setStatus(task, "failed", `第 ${seg.index + 1} 段配音失败：${r.error}`);
				return;
			}
			const probe = await probeMedia(out);
			seg.audioFile = out;
			seg.duration = probe.ok ? probe.duration : Math.max(1, seg.text.length / CHARS_PER_SEC);
			seg.start = cursor;
			seg.end = cursor + seg.duration;
			seg.status = "done";
			cursor = seg.end + .25;
			save(task);
			task.message = `配音 ${task.segments.filter((s) => s.status === "done").length}/${task.segments.length}`;
		}
		task.total_duration = cursor;
		save(task);
		setStatus(task, "visual", "正在拼接音轨...");
		const audioOut = join(dir, "narration.wav");
		const audioRes = await concatAudio(task.segments.map((s) => ({
			file: s.audioFile,
			silenceAfterMs: 250
		})), audioOut);
		if (!audioRes.ok) {
			setStatus(task, "failed", `音轨拼接失败：${audioRes.error}`);
			return;
		}
		setStatus(task, "visual", "正在生成画面...");
		const visualOut = join(dir, "visual.mp4");
		const duration = Math.max(1, task.total_duration);
		let visualInput = "";
		if (task.mode === "static") {
			if (!task.image_path || !existsSync(task.image_path)) {
				setStatus(task, "failed", "静态形象图模式下缺少图片素材");
				return;
			}
			const r = await imageToVideo(task.image_path, visualOut, duration);
			if (!r.ok) {
				setStatus(task, "failed", `画面生成失败：${r.error}`);
				return;
			}
			visualInput = visualOut;
		} else if (task.mode === "clip") {
			if (!task.clip_path || !existsSync(task.clip_path)) {
				setStatus(task, "failed", "视频素材模式下缺少视频素材");
				return;
			}
			const r = await ffmpeg$1([
				"-stream_loop",
				"-1",
				"-i",
				task.clip_path,
				"-t",
				String(duration),
				"-vf",
				"scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25",
				"-an",
				"-c:v",
				"libx264",
				"-pix_fmt",
				"yuv420p",
				"-preset",
				"medium",
				"-crf",
				"20",
				visualOut
			]);
			if (!r.ok) {
				setStatus(task, "failed", `画面生成失败：${r.error}`);
				return;
			}
			visualInput = visualOut;
		} else if (task.ai_per_segment) {
			const done = task.segments.filter((s) => s.status === "done");
			const pieceFiles = [];
			let ok = true;
			for (const [i, seg] of done.entries()) {
				const nextStart = done[i + 1]?.start ?? duration;
				const segDur = Math.max(1.5, nextStart - seg.start);
				setStatus(task, "visual", `正在生成第 ${i + 1}/${done.length} 段画面（每段约 2-4 分钟）...`);
				const ai = await generateAiVisual(`${task.ai_prompt ? `${task.ai_prompt}。` : ""}${seg.text}`.slice(0, 500), host, 5);
				if (!ai.ok || !ai.url) {
					ok = false;
					setStatus(task, "failed", `第 ${i + 1} 段 AI 画面失败：${ai.error}`);
					break;
				}
				const raw = join(dir, `ai-seg-${seg.index}.mp4`);
				const dl = await fetch(ai.url);
				if (!dl.ok) {
					ok = false;
					setStatus(task, "failed", `第 ${i + 1} 段画面下载失败 HTTP ${dl.status}`);
					break;
				}
				writeFileSync(raw, Buffer.from(await dl.arrayBuffer()));
				const piece = join(dir, `vis-seg-${seg.index}.mp4`);
				const r = await ffmpeg$1([
					"-stream_loop",
					"-1",
					"-i",
					raw,
					"-t",
					String(segDur),
					"-vf",
					"scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25",
					"-an",
					"-c:v",
					"libx264",
					"-pix_fmt",
					"yuv420p",
					"-preset",
					"medium",
					"-crf",
					"20",
					piece
				]);
				if (!r.ok) {
					ok = false;
					setStatus(task, "failed", `第 ${i + 1} 段画面处理失败：${r.error}`);
					break;
				}
				pieceFiles.push(piece);
			}
			if (!ok) return;
			if (pieceFiles.length === 0) {
				setStatus(task, "failed", "没有可用的画面片段");
				return;
			}
			const concatRes = await concatVideos(pieceFiles, visualOut);
			if (!concatRes.ok) {
				setStatus(task, "failed", `画面拼接失败：${concatRes.error}`);
				return;
			}
			visualInput = visualOut;
		} else {
			const prompt = task.ai_prompt || "cinematic background, soft lighting, no people";
			setStatus(task, "visual", "正在用 AI 生成画面（约 2-4 分钟）...");
			const ai = await generateAiVisual(prompt, host, 5);
			if (!ai.ok || !ai.url) {
				setStatus(task, "failed", `AI 画面失败：${ai.error}`);
				return;
			}
			const raw = join(dir, "ai-raw.mp4");
			const dl = await fetch(ai.url);
			if (!dl.ok) {
				setStatus(task, "failed", `AI 画面下载失败 HTTP ${dl.status}`);
				return;
			}
			writeFileSync(raw, Buffer.from(await dl.arrayBuffer()));
			const r = await ffmpeg$1([
				"-stream_loop",
				"-1",
				"-i",
				raw,
				"-t",
				String(duration),
				"-vf",
				"scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25",
				"-an",
				"-c:v",
				"libx264",
				"-pix_fmt",
				"yuv420p",
				"-preset",
				"medium",
				"-crf",
				"20",
				visualOut
			]);
			if (!r.ok) {
				setStatus(task, "failed", `画面生成失败：${r.error}`);
				return;
			}
			visualInput = visualOut;
		}
		setStatus(task, "muxing", "正在合成最终视频...");
		let cues;
		if (task.burn_subtitles) {
			if (!findCjkFont()) {
				setStatus(task, "failed", "缺少中文字体，无法烧录字幕（请安装中文字体或设置 AGNES_SUBTITLE_FONT）");
				return;
			}
			cues = task.segments.filter((s) => s.status === "done").map((s) => ({
				start: s.start,
				end: s.end,
				text: s.text
			}));
			writeFileSync(join(dir, "narration.srt"), buildSrt(cues), "utf8");
		}
		const finalOut = join(dir, "final.mp4");
		const mux = await muxNarration({
			visualInput,
			audioInput: audioOut,
			output: finalOut,
			cues
		});
		if (!mux.ok) {
			setStatus(task, "failed", `合成失败：${mux.error}`);
			return;
		}
		const probe = await probeMedia(finalOut);
		task.final_file = finalOut;
		task.total_duration = probe.ok ? probe.duration : duration;
		setStatus(task, "completed", `口播视频已生成（${task.segments.length} 段，${task.total_duration.toFixed(1)}s）`);
	} catch (e) {
		setStatus(task, "failed", e instanceof Error ? e.message : String(e));
	} finally {
		runningAnchors.delete(task.anchor_id);
	}
}
async function handleAnchorRoute(method, urlPath, body, host) {
	const dp = urlPath.replace(/^\/agnes-studio\/api\/?/, "").replace(/^anchor\/?/, "");
	if (method === "POST" && dp === "start") {
		const text = String(body?.text ?? "").trim();
		if (!text) return {
			status: 400,
			data: { error: "文稿内容为空" }
		};
		const mode = body?.mode === "clip" || body?.mode === "ai" ? body.mode : "static";
		const minSegSec = Math.min(20, Math.max(3, Number(body?.min_seg_sec ?? 4)));
		const texts = segmentText(text, minSegSec);
		if (texts.length === 0) return {
			status: 400,
			data: { error: "文稿分段为空" }
		};
		const id = randomUUID().slice(0, 12);
		const dir = anchorDir(id);
		const task = {
			anchor_id: id,
			text,
			mode,
			status: "pending",
			message: "准备中...",
			voice: typeof body?.voice === "string" && body.voice ? body.voice : "mimo_default",
			min_seg_sec: minSegSec,
			burn_subtitles: body?.subtitles !== false,
			segments: texts.map((t, i) => ({
				index: i,
				text: t,
				status: "pending",
				start: 0,
				end: 0,
				duration: 0
			})),
			total_duration: 0,
			created_at: Date.now(),
			updated_at: Date.now()
		};
		if (mode === "static") {
			if (!body?.image?.value) return {
				status: 400,
				data: { error: "静态形象图模式需要提供图片" }
			};
			const m = await materialize$3(body.image, join(dir, "avatar"));
			if (!m.ok) return {
				status: 400,
				data: { error: m.error }
			};
			task.image_path = m.file;
		} else if (mode === "clip") {
			if (!body?.clip?.value) return {
				status: 400,
				data: { error: "视频素材模式需要提供视频" }
			};
			const m = await materialize$3(body.clip, join(dir, "source"));
			if (!m.ok) return {
				status: 400,
				data: { error: m.error }
			};
			task.clip_path = m.file;
		} else {
			task.ai_prompt = String(body?.ai_prompt ?? "").trim() || void 0;
			task.ai_per_segment = body?.ai_per_segment === true;
		}
		save(task);
		runningAnchors.add(id);
		runAnchor(task, host);
		return {
			status: 200,
			data: {
				anchor_id: id,
				segments: texts.length,
				status: "pending"
			}
		};
	}
	if (method === "GET" && dp === "list") return {
		status: 200,
		data: { tasks: Array.from(anchorTasks.values()).slice(0, 20) }
	};
	const parts = dp.split("/");
	const id = parts[0];
	if (!id) return null;
	const task = anchorTasks.get(id) || load(id);
	if (!task) return {
		status: 404,
		data: { error: "任务不存在" }
	};
	if (method === "GET" && parts.length === 1) return {
		status: 200,
		data: task
	};
	if (method === "POST" && parts[1] === "stop") {
		task.status = "stopped";
		task.message = "已停止";
		save(task);
		runningAnchors.delete(id);
		return {
			status: 200,
			data: { ok: true }
		};
	}
	if (method === "POST" && parts[1] === "resume") {
		if (!runningAnchors.has(id) && task.status !== "completed") {
			runningAnchors.add(id);
			runAnchor(task, host);
		}
		return {
			status: 200,
			data: { ok: true }
		};
	}
	if (method === "GET" && parts[1] === "status") {
		const done = task.segments.filter((s) => s.status === "done").length;
		return {
			status: 200,
			data: {
				anchor_id: task.anchor_id,
				status: task.status,
				message: task.message,
				segments: task.segments.length,
				done,
				total_duration: task.total_duration,
				error: task.error ?? null,
				final: task.status === "completed" ? `/agnes-studio/api/media/anchor/${task.anchor_id}/final.mp4` : null
			}
		};
	}
	return null;
}
/** Restrict anchor media requests to the anchor's own directory. */
function resolveAnchorMedia(anchorId, filename) {
	if (!anchorId || !filename) return null;
	const dir = resolve(anchorDir(anchorId));
	const candidate = resolve(dir, basename(filename));
	if (!candidate.startsWith(dir + "/") && !candidate.startsWith(dir + "\\")) return null;
	return existsSync(candidate) && statSync(candidate).isFile() ? candidate : null;
}
/** Startup cleanup: mark jobs interrupted by a restart so the UI is not stuck. */
function rehydrateAnchors() {
	try {
		const root = join(dataRoot(), "anchors");
		if (!existsSync(root)) return;
		let count = 0;
		for (const d of readdirSync(root)) {
			const t = load(d);
			if (!t) continue;
			anchorTasks.set(d, t);
			if ([
				"pending",
				"tts",
				"visual",
				"muxing"
			].includes(t.status)) {
				t.status = "failed";
				t.message = "进程重启导致中断，可点击「重新生成」";
				save(t);
				count++;
			}
		}
		if (count) console.log(`[口播] 已恢复 ${count} 个中断任务`);
	} catch {}
}
//#endregion
//#region server/engines/bgvideo-engine.ts
/**
* 背景视频引擎 — Host 端核心逻辑（阶段 1-2：基础框架 + 风格截图）
* 管理背景视频任务的创建、状态、分幕、风格截图和持久化。
*
* 功能：
* - 上传素材（音频/歌词/文稿/参考片）
* - 启动任务（分幕）
* - 查询状态
* - 获取分幕结果
* - 停止任务
* - 任务列表
* - 风格截图上传/管理
* - 风格提炼
* - 一键出方案
*/
const bgVideoTasks = /* @__PURE__ */ new Map();
const BGVIDEO_DIR = join(dataRoot(), "bgvideo");
function getBgVideoPath(id) {
	const dir = join(BGVIDEO_DIR, id);
	mkdirSync(dir, { recursive: true });
	return join(dir, "task.json");
}
function saveToDisk$4(task) {
	try {
		writeFileSync(getBgVideoPath(task.task_id), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function loadFromDisk$4(id) {
	try {
		const p = getBgVideoPath(id);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
/**
* 处理背景视频相关路由。
* @returns null 表示不匹配该路由
*/
async function handleBgVideoRoute(method, path, body, host) {
	const rest = path.slice(25).replace(/^\//, "");
	const sub = rest.split("?")[0];
	const url = new URL(`http://dsh.invalid/${rest}`);
	const Q = (k) => url.searchParams.get(k) || "";
	const B = body;
	const pick = (id) => id ? bgVideoTasks.get(id) || loadFromDisk$4(id) : null;
	const need = (id) => {
		const t = pick(id);
		if (!t) throw new Error("任务不存在：" + (id || "(空)"));
		return t;
	};
	const touch = (t) => {
		t.updated_at = Date.now();
		saveToDisk$4(t);
	};
	const log = (t, line) => {
		t.genlog = [...t.genlog || [], `[${(/* @__PURE__ */ new Date()).toISOString().slice(11, 19)}] ${line}`].slice(-200);
	};
	try {
		if (method === "GET" && sub === "tasks") return {
			status: 200,
			data: {
				success: true,
				tasks: Array.from(bgVideoTasks.values()).sort((a, b) => b.created_at - a.created_at).slice(0, 30)
			}
		};
		if (method === "POST" && sub === "tasks/clear") {
			bgVideoTasks.clear();
			return {
				status: 200,
				data: { success: true }
			};
		}
		if (method === "GET" && sub.startsWith("status")) {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					task: t
				}
			};
		}
		if (method === "POST" && sub === "stop") {
			const t = pick(String(B?.task_id || ""));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			t.status = "stopped";
			t.message = "已停止";
			log(t, "用户停止");
			touch(t);
			return {
				status: 200,
				data: { success: true }
			};
		}
		if (method === "POST" && sub === "upload") {
			const kind = String(B.kind || "");
			const content = String(B.content || "");
			if (!kind) return {
				status: 400,
				data: { error: "缺少 kind（audio / script / refvideo / style）" }
			};
			if (!content) return {
				status: 400,
				data: { error: "缺少 content（链接、路径或 data URI）" }
			};
			const t = B.task_id ? need(String(B.task_id)) : null;
			const dir = t ? join(BGVIDEO_DIR, t.task_id) : join(BGVIDEO_DIR, "_uploads");
			mkdirSync(dir, { recursive: true });
			const safe = String(B.filename || `${kind}-${Date.now()}`).replace(/[/\\:*?"<>|]/g, "_");
			const out = join(dir, safe);
			await materialize$2(content, out, kind);
			if (t) {
				if (kind === "audio") t.accompaniment_file = out;
				else if (kind === "script") t.script_file = out;
				else if (kind === "refvideo") t.refvideo_file = out;
				else t.style_refs = [...t.style_refs || [], out];
				log(t, `素材落盘 ${kind}：${safe}`);
				touch(t);
			}
			return {
				status: 200,
				data: {
					success: true,
					kind,
					filename: safe,
					path: out
				}
			};
		}
		if (method === "POST" && sub === "generate") {
			if (B.task_id && !B.resplit) {
				const t = need(String(B.task_id));
				if (!(t.segments || []).length) throw new Error("这个任务还没有分幕：先分幕再出片");
				log(t, "开始出片");
				touch(t);
				runGeneration(t.task_id, host).catch(() => {});
				return {
					status: 200,
					data: {
						success: true,
						task_id: t.task_id,
						note: "已开始出片"
					}
				};
			}
			if (!B.script_text && !B.script_file && !B.audio_file) return {
				status: 400,
				data: { error: "至少给一段文稿（或文稿文件 / 音频）" }
			};
			const taskId = randomUUID().slice(0, 8);
			const task = {
				task_id: taskId,
				status: "segmenting",
				message: "正在分幕…",
				audio_file: B.audio_file,
				lrc_file: B.lrc_file,
				script_file: B.script_file,
				refvideo_file: B.refvideo_file,
				accompaniment_file: B.accompaniment_file,
				asr_model: B.asr_model || "small",
				scene: B.scene || "",
				role: B.role || "",
				voice: B.voice || "xiaoxiao",
				frame_every_sec: B.frame_every_sec || 2,
				plan_only: B.plan_only ?? false,
				script_text: B.script_text,
				scenes_count: Math.max(3, Math.min(24, Number(B.scenes_count) || 8)),
				text_model: B.text_model || "agnes-3.0-flash",
				image_model: B.image_model || "agnes-image-2.5-flash",
				genlog: ["任务创建"],
				created_at: Date.now(),
				updated_at: Date.now()
			};
			bgVideoTasks.set(taskId, task);
			saveToDisk$4(task);
			runSegmentation(taskId, host).catch(() => {});
			return {
				status: 200,
				data: {
					success: true,
					task_id: taskId
				}
			};
		}
		if (method === "GET" && sub === "segments") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					segments: t.segments || [],
					total: t.total || 0
				}
			};
		}
		if (method === "GET" && sub === "storyboard") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					shots: t.shots || [],
					template: SHOT_TEMPLATE
				}
			};
		}
		if (method === "POST" && sub === "write_shots") {
			const t = need(String(B.task_id || ""));
			t.shots = await buildShots(host, t);
			log(t, `镜头表已生成（${t.shots.length} 镜）`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					shots: t.shots
				}
			};
		}
		if (method === "POST" && sub === "storyboard/describe") {
			const t = need(String(B.task_id || ""));
			const index = Number(B.index || 1);
			const shot = (t.shots || []).find((x) => x.index === index);
			if (!shot) return {
				status: 404,
				data: { error: `没有第 ${index} 镜` }
			};
			shot.desc = (await callChat$2(host, t.text_model || "agnes-3.0-flash", "你是分镜师，擅长把一句话扩成可拍摄的画面描述。", `把这一镜扩写成 1–2 句可拍 / 可画的具体画面：${shot.desc}\n景别 ${shot.camera || "不限"}，运镜 ${shot.movement || "不限"}。只输出画面描述。`, 400)).trim();
			log(t, `第 ${index} 镜描述已重写`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					shot
				}
			};
		}
		if (method === "POST" && sub === "storyboard/remap") {
			const t = need(String(B.task_id || ""));
			const cur = t.shots || [];
			if (!cur.length) return {
				status: 400,
				data: { error: "还没有镜头表" }
			};
			const order = Array.isArray(B.order) ? B.order.map(Number) : [];
			if (order.length) {
				const next = [];
				order.forEach((i, k) => {
					const f = cur.find((x) => x.index === Number(i));
					if (f) next.push({
						...f,
						index: k + 1
					});
				});
				if (next.length) t.shots = next;
			}
			log(t, `镜头已重排（${(t.shots || []).length} 镜）`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					shots: t.shots || []
				}
			};
		}
		if (method === "POST" && sub === "shots_template") return {
			status: 200,
			data: {
				success: true,
				template: SHOT_TEMPLATE
			}
		};
		if (method === "POST" && sub === "shots_apply") {
			const t = need(String(B.task_id || ""));
			const shots = Array.isArray(B.shots) ? B.shots : [];
			if (!shots.length) return {
				status: 400,
				data: { error: "缺少 shots" }
			};
			t.shots = shots.map((x, i) => ({
				index: i + 1,
				desc: String(x?.desc || ""),
				chars: Array.isArray(x?.chars) ? x.chars.map(String) : [],
				camera: x?.camera ? String(x.camera) : void 0,
				movement: x?.movement ? String(x.movement) : void 0
			}));
			log(t, `镜头表已写入（${t.shots.length} 镜）`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					shots: t.shots
				}
			};
		}
		if (method === "POST" && sub === "empty_shot_desc") {
			const t = need(String(B.task_id || ""));
			const all = t.shots || [];
			if (!all.length) return {
				status: 400,
				data: { error: "还没有镜头表" }
			};
			const empty = all.filter((s) => !String(s.desc || "").trim());
			const targets = empty.length ? empty : all;
			const arr = extractJsonArray$2(await callChat$2(host, t.text_model || "agnes-3.0-flash", "你是分镜师，负责为没有画面描述的空镜补描述。", "下面这些镜头缺少画面描述。请为每一个补一句可拍 / 可画的具体画面（主体+场景+光线+构图）。只输出 JSON 数组：[{\"index\":序号,\"desc\":\"描述\"}]。\n\n" + targets.map((s) => `${s.index}. ${s.desc || "(空)"}`).join("\n"), 1500));
			for (const it of arr) {
				const hit = all.find((s) => s.index === Number(it.index));
				if (hit && it.desc) hit.desc = String(it.desc);
			}
			log(t, `空镜描述已补（${arr.length} 镜）`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					shots: all
				}
			};
		}
		if (method === "GET" && sub === "contact_sheet") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			const dir = join(BGVIDEO_DIR, t.task_id);
			const imgs = (t.segments || []).map((x) => String(x.image || "")).filter(Boolean);
			const out = join(dir, "contact_sheet.jpg");
			await makeContactSheet(imgs.length ? imgs : t.style_refs || [], out);
			t.contact_sheet = out;
			log(t, "联系表已生成");
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					rel: `${t.task_id}/contact_sheet.jpg`
				}
			};
		}
		if (method === "GET" && sub === "characters") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					characters: t.characters || []
				}
			};
		}
		if (method === "POST" && sub === "characters/create") {
			const t = need(String(B.task_id || ""));
			const name = String(B.name || "").trim();
			if (!name) return {
				status: 400,
				data: { error: "缺少角色名" }
			};
			const c = {
				id: randomUUID().slice(0, 6),
				name,
				desc: String(B.desc || "").trim()
			};
			t.characters = [...t.characters || [], c];
			log(t, `新增角色：${name}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					character: c,
					characters: t.characters
				}
			};
		}
		if (method === "POST" && sub === "characters/update") {
			const t = need(String(B.task_id || ""));
			const c = (t.characters || []).find((x) => x.id === String(B.id || ""));
			if (!c) return {
				status: 404,
				data: { error: "角色不存在" }
			};
			if (B.name) c.name = String(B.name);
			if (B.desc !== void 0) c.desc = String(B.desc || "");
			log(t, `角色已更新：${c.name}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					character: c,
					characters: t.characters
				}
			};
		}
		if (method === "POST" && sub === "characters/delete") {
			const t = need(String(B.task_id || ""));
			const id = String(B.id || "");
			const before = (t.characters || []).length;
			t.characters = (t.characters || []).filter((x) => x.id !== id);
			log(t, `角色已删除（${before} → ${t.characters.length}）`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					characters: t.characters
				}
			};
		}
		if (method === "POST" && sub === "character/portrait") {
			const t = need(String(B.task_id || ""));
			const c = (t.characters || []).find((x) => x.id === String(B.id || ""));
			if (!c) return {
				status: 404,
				data: { error: "角色不存在" }
			};
			const dir = join(BGVIDEO_DIR, t.task_id);
			mkdirSync(dir, { recursive: true });
			const out = join(dir, `portrait_${c.id}.jpg`);
			const styleWord = t.style?.prompt ? `，风格：${t.style.prompt}` : "";
			const prompt = String(B.prompt || "").trim() || `${c.name} 的角色定妆照。${c.desc || "正面半身"}。单人，干净背景，正面光线，中性表情${styleWord}`;
			await genImage$1(host, t.image_model || "agnes-image-2.5-flash", prompt, out);
			c.portrait = out;
			log(t, `角色定妆照已生成：${c.name}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					character: c,
					rel: `${t.task_id}/portrait_${c.id}.jpg`
				}
			};
		}
		if (method === "POST" && sub === "character/refine") {
			const t = need(String(B.task_id || ""));
			const c = (t.characters || []).find((x) => x.id === String(B.id || ""));
			if (!c) return {
				status: 404,
				data: { error: "角色不存在" }
			};
			c.desc = (await callChat$2(host, t.text_model || "agnes-3.0-flash", "你是角色设计师，擅长把粗略设定写成可执行的、可视化的角色描述。", `把下面这个角色写成 3–5 句可用于生图与表演的设定：外貌（发型/服装/标志物）、气质、习惯动作、说话方式。\n\n角色名：${c.name}\n现有设定：${c.desc || "(空)"}\n\n只输出设定正文。`, 800)).trim();
			log(t, `角色设定已细化：${c.name}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					character: c,
					characters: t.characters
				}
			};
		}
		if (method === "POST" && sub === "style_refs") {
			const t = need(String(B.task_id || ""));
			const dir = join(BGVIDEO_DIR, t.task_id);
			mkdirSync(dir, { recursive: true });
			const srcs = Array.isArray(B.files) ? B.files.map(String) : B.file ? [String(B.file)] : [];
			if (!srcs.length) return {
				status: 400,
				data: { error: "缺少 files（链接或路径数组）" }
			};
			const added = [];
			for (let i = 0; i < srcs.length; i++) {
				const out = join(dir, `style_${Date.now()}_${i}.jpg`);
				await materialize$2(srcs[i], out, "参考图");
				added.push(out);
			}
			t.style_refs = [...t.style_refs || [], ...added];
			log(t, `风格参考图 +${added.length}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					style_refs: added.map((f) => `${t.task_id}/${f.split("/").pop()}`)
				}
			};
		}
		if (method === "GET" && sub === "style_refs") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					style_refs: (t.style_refs || []).map((f) => ({
						name: f.split("/").pop(),
						rel: `${t.task_id}/${f.split("/").pop()}`
					}))
				}
			};
		}
		if (method === "POST" && sub === "style_refs/clear") {
			const t = need(String(B.task_id || ""));
			t.style_refs = [];
			log(t, "风格参考图已清空");
			touch(t);
			return {
				status: 200,
				data: { success: true }
			};
		}
		if (method === "POST" && sub === "style_refs/distill") {
			const t = need(String(B.task_id || ""));
			t.style = await distillStyle(host, t);
			log(t, "风格已提炼");
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					style: t.style
				}
			};
		}
		if (method === "GET" && sub === "style") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					style: t.style || null,
					presets: STYLE_PRESETS
				}
			};
		}
		if (method === "POST" && sub === "style/detect") {
			const t = need(String(B.task_id || ""));
			if ((t.style_refs || []).length) t.style = await distillStyle(host, t);
			else {
				const hit = STYLE_PRESETS.find((x) => x.key === String(B.preset || "cinematic")) || STYLE_PRESETS[0];
				t.style = {
					prompt: hit.prompt,
					negative: hit.negative
				};
			}
			log(t, "风格已检测 / 写入");
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					style: t.style
				}
			};
		}
		if (method === "GET" && sub === "style_presets") return {
			status: 200,
			data: {
				success: true,
				presets: STYLE_PRESETS
			}
		};
		if (method === "GET" && sub === "design_template") return {
			status: 200,
			data: {
				success: true,
				template: {
					roles: [
						"主角",
						"对手",
						"配角"
					],
					fields: [
						"name",
						"desc",
						"portrait"
					],
					note: "先建角色 → 出定妆照 → 再写分镜，人物一致性会好很多"
				}
			}
		};
		if (method === "POST" && sub === "design_style") {
			const t = need(String(B.task_id || ""));
			const brief = await callChat$2(host, t.text_model || "agnes-3.0-flash", "你是视觉总监，负责把一个题材定成统一的视觉方案。", `给这个题材写一份视觉方案：色调、光线、材质、镜头倾向、要避免的东西。\n题材 / 文稿摘要：${String(B.brief || t.script_text || t.scene || "").slice(0, 1500)}\n\n只输出方案正文（200 字内）。`, 700);
			t.design = {
				...t.design || {},
				brief: brief.trim()
			};
			log(t, "视觉方案已生成");
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					design: t.design
				}
			};
		}
		if (method === "POST" && sub === "design_apply") {
			const t = need(String(B.task_id || ""));
			const brief = String(B.brief || t.design?.brief || "").trim();
			if (!brief) return {
				status: 400,
				data: { error: "还没有视觉方案：先跑一次 design_style" }
			};
			const segs = t.segments || [];
			if (!segs.length) return {
				status: 400,
				data: { error: "还没有分幕" }
			};
			const arr = extractJsonArray$2(await callChat$2(host, t.text_model || "agnes-3.0-flash", "你是分镜师，负责把统一视觉方案套到每一幕画面上。", `把下面的视觉方案融进每一幕的画面描述里（保持原意，只补风格词）。\n只输出 JSON 数组：[{"index":序号,"scene":"改写后的画面描述"}]。\n\n【视觉方案】\n${brief}\n\n【原分幕】\n` + segs.map((x) => `${x.index}. ${x.scene || x.text}`).join("\n"), 3e3));
			for (const it of arr) {
				const hit = segs.find((x) => x.index === Number(it.index));
				if (hit && it.scene) hit.scene = String(it.scene);
			}
			log(t, `视觉方案已套用到 ${arr.length} 幕`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					segments: segs
				}
			};
		}
		if (method === "POST" && (sub === "anchor/auto" || sub === "anchor/scan")) {
			const t = need(String(B.task_id || ""));
			const src = String(t.refvideo_file || "").trim();
			if (!src) return {
				status: 400,
				data: { error: "任务里没有参考视频：先上传 refvideo" }
			};
			const dir = join(BGVIDEO_DIR, t.task_id);
			mkdirSync(dir, { recursive: true });
			const local = await materialize$2(src, join(dir, "ref_source.mp4"), "参考视频");
			const info = await probeMedia(local);
			const dur = Number(info.duration || 0) || 10;
			const n = Math.max(2, Math.min(8, Number(B.count) || 4));
			const found = [];
			for (let i = 0; i < n; i++) {
				const at = dur * (i + .5) / n;
				const out = join(dir, `anchor_${String(i + 1).padStart(2, "0")}.jpg`);
				if ((await ffmpeg([
					"-ss",
					at.toFixed(2),
					"-i",
					local,
					"-frames:v",
					"1",
					"-vf",
					"scale=640:-2",
					"-q:v",
					"3",
					out
				], 12e4)).ok && existsSync(out)) found.push(out);
			}
			if (!found.length) return {
				status: 500,
				data: { error: "没能从参考视频里抽到可用帧" }
			};
			t.anchors = found;
			log(t, `锚图候选 +${found.length}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					anchors: found.map((f) => `${t.task_id}/${f.split("/").pop()}`)
				}
			};
		}
		if (method === "POST" && (sub === "anchor/promote" || sub === "anchor/reject" || sub === "anchor/remove" || sub === "anchor/crop" || sub === "anchor/import")) {
			const t = need(String(B.task_id || ""));
			if (sub === "anchor/reject" || sub === "anchor/remove") {
				const key = String(B.rel || B.name || "").split("/").pop() || "";
				const before = (t.anchors || []).length;
				t.anchors = (t.anchors || []).filter((f) => !f.endsWith(key));
				log(t, `锚图移除（${before} → ${t.anchors.length}）`);
				touch(t);
				return {
					status: 200,
					data: {
						success: true,
						anchors: t.anchors
					}
				};
			}
			const src = String(B.src || B.content || "").trim();
			if (!src) return {
				status: 400,
				data: { error: "缺少 src（图片链接或路径）" }
			};
			const dir = join(BGVIDEO_DIR, t.task_id);
			mkdirSync(dir, { recursive: true });
			const out = join(dir, `anchor_${Date.now()}.jpg`);
			await materialize$2(src, out, "锚图");
			if (sub !== "anchor/crop") t.anchors = [...t.anchors || [], out];
			log(t, `锚图 ${sub}：${out.split("/").pop()}`);
			touch(t);
			return {
				status: 200,
				data: {
					success: true,
					anchors: t.anchors || [],
					rel: `${t.task_id}/${out.split("/").pop()}`
				}
			};
		}
		if (method === "GET" && sub === "frames") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			const frames = [];
			try {
				for (const f of readdirSync(join(BGVIDEO_DIR, t.task_id))) if (/\.(jpg|jpeg|png|webp)$/i.test(f)) frames.push(`${t.task_id}/${f}`);
			} catch {}
			return {
				status: 200,
				data: {
					success: true,
					frames,
					segments: t.segments || []
				}
			};
		}
		if (method === "GET" && sub === "genlog") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					log: t.genlog || [],
					status: t.status,
					message: t.message
				}
			};
		}
		if (method === "GET" && sub === "reqfiles") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					files: {
						audio_file: t.audio_file,
						lrc_file: t.lrc_file,
						script_file: t.script_file,
						refvideo_file: t.refvideo_file,
						accompaniment_file: t.accompaniment_file,
						style_refs: t.style_refs || []
					}
				}
			};
		}
		if (method === "GET" && sub === "reqfile") {
			const t = pick(Q("task_id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			const key = Q("key");
			const val = t[key];
			return {
				status: 200,
				data: {
					success: true,
					key,
					value: typeof val === "string" ? val : null
				}
			};
		}
		return null;
	} catch (e) {
		return {
			status: 500,
			data: { error: e instanceof Error ? e.message : String(e) }
		};
	}
}
/** 八种常用镜头，供分镜模板选用。 */
const SHOT_TEMPLATE = [
	{
		name: "建立镜头",
		camera: "远景",
		movement: "缓慢横移",
		hint: "交代环境与人物位置，不入戏"
	},
	{
		name: "氛围空镜",
		camera: "中景",
		movement: "固定",
		hint: "用光影或天气传递情绪，无人物或背影"
	},
	{
		name: "人物入场",
		camera: "中近景",
		movement: "跟随",
		hint: "跟随人物走位进入画面，脚步声中带节奏"
	},
	{
		name: "情绪特写",
		camera: "特写",
		movement: "缓慢推近",
		hint: "面部或手部细节，配合呼吸与微表情"
	},
	{
		name: "对话正反打",
		camera: "近景",
		movement: "固定",
		hint: "两人交替，视线方向相反，留出视线空间"
	},
	{
		name: "动作高潮",
		camera: "全景",
		movement: "快速跟摇",
		hint: "动作连贯不切碎，一个镜头一个完整动作"
	},
	{
		name: "转场过渡",
		camera: "中景",
		movement: "甩镜/遮挡",
		hint: "用遮挡物或运动模糊接下一镜"
	},
	{
		name: "收尾定帧",
		camera: "中远景",
		movement: "缓慢拉远",
		hint: "情绪落地，画面留白给字幕或旁白"
	}
];
/** 六套风格预设，供「风格」用。 */
const STYLE_PRESETS = [
	{
		key: "cinematic",
		name: "电影感",
		prompt: "电影级布光，浅景深，胶片颗粒，冷暖对比",
		negative: "过曝，塑料感，卡通"
	},
	{
		key: "documentary",
		name: "纪实",
		prompt: "自然光，手持轻微晃动，真实市井质感",
		negative: "浓妆，舞台光，滤镜"
	},
	{
		key: "anime",
		name: "日系动画",
		prompt: "赛璐璐上色，干净线条，高饱和天空",
		negative: "写实皮肤纹理，3D 渲染"
	},
	{
		key: "ink",
		name: "水墨",
		prompt: "宣纸质感，留白构图，墨色浓淡层次",
		negative: "写实照片，霓虹色"
	},
	{
		key: "cyberpunk",
		name: "赛博朋克",
		prompt: "霓虹反射，雨夜湿地，青紫对撞，体积光",
		negative: "日光，田园，暖黄"
	},
	{
		key: "warm",
		name: "温暖生活",
		prompt: "暖黄台灯，木质室内，柔和阴影",
		negative: "冷蓝，强对比，恐怖氛围"
	}
];
async function callChat$2(host, model, system, user, maxTokens = 2500) {
	const text = (await host.call(getVendorFromModel(model), "/v1/chat/completions", {
		method: "POST",
		body: {
			model,
			messages: [{
				role: "system",
				content: system
			}, {
				role: "user",
				content: user
			}],
			temperature: .8,
			max_tokens: maxTokens
		},
		timeoutMs: 3e5
	}))?.choices?.[0]?.message?.content;
	if (!text || !String(text).trim()) throw new Error("模型没有返回内容（检查 Key 与模型名）");
	return String(text);
}
function extractJsonArray$2(raw) {
	const str = String(raw);
	const fence = str.match(/```(?:json)?\s*([\s\S]*?)```/i);
	const body = fence ? fence[1] : str;
	const a = body.indexOf("[");
	const b = body.lastIndexOf("]");
	if (a < 0 || b <= a) return [];
	try {
		const arr = JSON.parse(body.slice(a, b + 1));
		return Array.isArray(arr) ? arr : [];
	} catch {
		return [];
	}
}
/** 把素材落到本地：支持 data URI / http(s) / 服务器本地路径。 */
async function materialize$2(src, outFile, kind) {
	const v = String(src || "").trim();
	if (!v) throw new Error(`缺少${kind}来源`);
	if (v.startsWith("data:")) {
		const b64 = v.slice(v.indexOf(",") + 1);
		if (!b64) throw new Error(`${kind}的 data URI 是空的`);
		writeFileSync(outFile, Buffer.from(b64, "base64"));
		return outFile;
	}
	if (/^https?:\/\//i.test(v)) {
		const resp = await fetch(v, { signal: AbortSignal.timeout(6e5) });
		if (!resp.ok) throw new Error(`${kind}下载失败：HTTP ${resp.status}`);
		const buf = Buffer.from(await resp.arrayBuffer());
		if (!buf.length) throw new Error(`${kind}下载到的是空文件`);
		writeFileSync(outFile, buf);
		return outFile;
	}
	if (!existsSync(v)) throw new Error(`${kind}文件不存在：${v}`);
	return v;
}
/** 读一份文稿：本地路径直接读，http(s) 先下载。 */
async function readSource(src) {
	const v = String(src || "").trim();
	if (/^https?:\/\//i.test(v)) {
		const resp = await fetch(v, { signal: AbortSignal.timeout(12e4) });
		if (!resp.ok) throw new Error(`文稿下载失败：HTTP ${resp.status}`);
		return await resp.text();
	}
	if (!existsSync(v)) throw new Error(`文稿文件不存在：${v}`);
	return readFileSync(v, "utf8");
}
async function genImage$1(host, model, prompt, outFile) {
	const data = await host.call(getVendorFromModel(model), "/v1/images/generations", {
		method: "POST",
		body: {
			model,
			prompt,
			size: "1024x1024",
			extra_body: { response_format: "url" }
		},
		timeoutMs: 3e5
	});
	const first = Array.isArray(data?.data) ? data.data[0] : null;
	const url = first?.url || (first?.b64_json ? `data:image/png;base64,${first.b64_json}` : "");
	if (!url) throw new Error("生图接口没有返回图片（检查图像模型与 Key）");
	await materialize$2(String(url), outFile, "画面");
}
/** 把分幕转成镜头表（文本模型）。 */
async function buildShots(host, task) {
	const segs = task.segments || [];
	if (!segs.length) throw new Error("还没有分幕：先跑一次分幕");
	const arr = extractJsonArray$2(await callChat$2(host, task.text_model || "agnes-3.0-flash", "你是分镜师，负责把画面段落转成可拍摄的镜头表。", [
		`下面有 ${segs.length} 幕画面描述，请为每一幕给出一组镜头要素。`,
		"输出 JSON 数组，每项：{\"index\":序号,\"desc\":\"画面描述\",\"camera\":\"景别\",\"movement\":\"运镜\",\"chars\":[\"出场角色名\"]}。",
		"景别用：远景/全景/中景/中近景/近景/特写；运镜用：固定/缓慢推近/缓慢拉远/横移/跟随/跟摇/甩镜。",
		"chars 只填下面【角色表】里出现过的名字，没有就留空数组。",
		"只输出 JSON，不要解释。",
		"",
		"【角色表】",
		(task.characters || []).map((c) => c.name).join("、") || "（暂无）",
		"",
		"【分幕】",
		segs.map((x) => `${x.index}. ${x.scene || x.text || ""}`).join("\n")
	].join("\n"), 3e3));
	const shots = [];
	for (let i = 0; i < segs.length; i++) {
		const it = arr.find((x) => Number(x.index) === i + 1) || arr[i] || {};
		shots.push({
			index: i + 1,
			desc: String(it.desc || segs[i].scene || segs[i].text || "").trim(),
			chars: Array.isArray(it.chars) ? it.chars.map(String) : [],
			camera: String(it.camera || "").trim() || void 0,
			movement: String(it.movement || "").trim() || void 0
		});
	}
	return shots;
}
/** 用多模态模型从若干参考图里提炼一句风格提示词。 */
async function distillStyle(host, task) {
	const refs = (task.style_refs || []).filter((f) => existsSync(f));
	if (!refs.length) throw new Error("还没有风格参考图：先上传或指定图片");
	const model = task.text_model || "agnes-2.5-flash";
	const vendor = getVendorFromModel(model);
	const content = [{
		type: "text",
		text: "下面是几张风格参考图。请提炼它们的共同视觉风格，输出 JSON：{\"prompt\":\"可直接用于生图的中文风格描述（色调+光线+材质+构图倾向，60字内）\",\"negative\":\"要避免的相反风格（20字内）\"}。只输出 JSON。"
	}];
	for (const f of refs.slice(0, 4)) try {
		content.push({
			type: "image_url",
			image_url: { url: `data:image/jpeg;base64,${readFileSync(f).toString("base64")}` }
		});
	} catch {}
	const resp = await host.call(vendor, "/v1/chat/completions", {
		method: "POST",
		body: {
			model,
			messages: [{
				role: "user",
				content
			}],
			temperature: .4,
			max_tokens: 500
		},
		timeoutMs: 18e4
	});
	const text = String(resp?.choices?.[0]?.message?.content || "");
	const obj = extractJsonArray$2(text)[0] || {};
	if (!text.trim()) throw new Error("模型没有返回内容（检查 Key，以及该模型是否支持读图）");
	return {
		prompt: String(obj.prompt || text.trim()).slice(0, 400),
		negative: String(obj.negative || "").slice(0, 200)
	};
}
/** 把若干张图拼成一张联系表（ffmpeg xstack）。 */
async function makeContactSheet(files, outFile) {
	const usable = files.filter((f) => f && existsSync(f)).slice(0, 16);
	if (!usable.length) throw new Error("还没有可拼的画面：先生成或上传图片");
	const cellW = 320;
	const cellH = 180;
	const n = usable.length;
	const args = [];
	for (const f of usable) args.push("-i", f);
	const scaleAll = usable.map((_, i) => `[${i}:v]scale=${cellW}:${cellH}[v${i}]`).join(";");
	const layout = usable.map((_, i) => `${i % 4 * cellW}_${Math.floor(i / 4) * cellH}`).join("|");
	const filter = `${scaleAll};${usable.map((_, i) => `[v${i}]`).join("")}xstack=inputs=${n}:layout=${layout}:fill=black[out]`;
	const r = await ffmpeg([
		...args,
		"-filter_complex",
		filter,
		"-map",
		"[out]",
		"-frames:v",
		"1",
		outFile
	], 12e4);
	if (!r.ok) throw new Error("联系表合成失败：" + (r.error || ""));
}
async function runSegmentation(taskId, host) {
	const task = bgVideoTasks.get(taskId);
	if (!task) return;
	const model = task.text_model || "agnes-3.0-flash";
	try {
		task.status = "segmenting";
		task.message = "正在分幕…";
		task.updated_at = Date.now();
		saveToDisk$4(task);
		const dir = join(BGVIDEO_DIR, taskId);
		mkdirSync(dir, { recursive: true });
		let script = String(task.script_text || "").trim();
		if (!script && task.script_file) script = await readSource(String(task.script_file));
		if (!script.trim()) throw new Error("没有文稿：请在「文稿」里填内容，或给一个能读到的文稿文件路径");
		const n = Math.max(3, Math.min(24, task.scenes_count || 8));
		const arr = extractJsonArray$2(await callChat$2(host, model, "你是短视频的分幕导演，擅长把一段文稿切成等长的画面段落。", [
			`把下面这段文稿切成 ${n} 幕。`,
			"每一幕给：该幕对应的原文片段（尽量短）+ 一句可直接生图的画面描述（主体 + 场景 + 光线 + 构图 + 风格）。",
			"画面之间要有视觉连贯性（同一世界、同一色调倾向），不要每幕换风格。",
			"只输出 JSON 数组：[{\"text\":\"原文片段\",\"scene\":\"画面描述\"}]，不要任何解释。",
			"",
			"【文稿】",
			script.slice(0, 6e3)
		].join("\n"), 3e3));
		const segs = [];
		for (let i = 0; i < arr.length && segs.length < n; i++) {
			const text = String(arr[i]?.text || "").trim();
			const scene = String(arr[i]?.scene || "").trim();
			if (!scene) continue;
			segs.push({
				index: segs.length + 1,
				start: 0,
				end: 0,
				text: text || scene,
				chars: [],
				scene
			});
		}
		if (!segs.length) throw new Error("模型没有给出可用的分幕");
		task.segments = segs;
		task.total = segs.length;
		task.status = "planned";
		task.message = `分幕完成：${segs.length} 幕，可以继续出片`;
		task.updated_at = Date.now();
		saveToDisk$4(task);
	} catch (e) {
		task.status = "failed";
		task.message = "分幕失败：" + (e instanceof Error ? e.message : String(e));
		task.updated_at = Date.now();
		saveToDisk$4(task);
	}
}
async function runGeneration(taskId, host) {
	const task = bgVideoTasks.get(taskId);
	if (!task) return;
	const imageModel = task.image_model || "agnes-image-2.5-flash";
	try {
		const dir = join(BGVIDEO_DIR, taskId);
		mkdirSync(dir, { recursive: true });
		const segs = task.segments || [];
		if (!segs.length) throw new Error("还没有分幕：先跑一次分幕");
		task.status = "imaging";
		for (let i = 0; i < segs.length; i++) {
			task.message = `正在生成第 ${i + 1}/${segs.length} 幕画面…`;
			task.updated_at = Date.now();
			saveToDisk$4(task);
			const out = join(dir, `seg_${String(i + 1).padStart(2, "0")}.jpg`);
			await genImage$1(host, imageModel, segs[i].scene || segs[i].text, out);
			segs[i].image = out;
			saveToDisk$4(task);
		}
		let total = 0;
		let audioPath = "";
		const audioSrc = task.accompaniment_file || task.audio_file;
		if (audioSrc) {
			audioPath = await materialize$2(String(audioSrc), join(dir, "audio.mp3"), "音乐");
			const info = await probeMedia(audioPath);
			total = Number(info.duration || 0);
		}
		if (!(total > 0)) total = segs.length * Math.max(2, (task.frame_every_sec || 2) * 2);
		const per = Math.max(1.5, total / segs.length);
		task.status = "rendering";
		const clips = [];
		for (let i = 0; i < segs.length; i++) {
			task.message = `正在合成第 ${i + 1}/${segs.length} 段…`;
			task.updated_at = Date.now();
			saveToDisk$4(task);
			const clip = join(dir, `clip_${String(i + 1).padStart(2, "0")}.mp4`);
			const r = await imageToVideo(String(segs[i].image || ""), clip, per, {
				width: 1280,
				height: 720
			});
			if (!r.ok) throw new Error("合成片段失败：" + (r.error || ""));
			clips.push(clip);
		}
		task.message = "正在拼接…";
		task.updated_at = Date.now();
		saveToDisk$4(task);
		const merged = join(dir, "merged.mp4");
		const cat = await concatVideos(clips, merged, { reencode: true });
		if (!cat.ok) throw new Error("拼接失败：" + (cat.error || ""));
		let note = "";
		if (audioPath) {
			task.message = "正在配乐…";
			task.updated_at = Date.now();
			saveToDisk$4(task);
			const final = join(dir, "final.mp4");
			const mux = await muxNarration({
				visualInput: merged,
				audioInput: audioPath,
				output: final
			});
			if (mux.ok) task.video_id = "final.mp4";
			else {
				task.video_id = "merged.mp4";
				note = "（配乐失败，成片无音轨：" + (mux.error || "") + "）";
			}
		} else {
			task.video_id = "merged.mp4";
			note = "（没有提供音乐，成片无音轨）";
		}
		task.status = "completed";
		task.message = `成片完成：${segs.length} 幕，每幕约 ${per.toFixed(1)} 秒 ${note}`;
		task.updated_at = Date.now();
		saveToDisk$4(task);
	} catch (e) {
		task.status = "failed";
		task.error = e instanceof Error ? e.message : String(e);
		task.message = "出片失败：" + task.error;
		task.updated_at = Date.now();
		saveToDisk$4(task);
	}
}
function rehydrateBgVideos() {
	try {
		if (!existsSync(BGVIDEO_DIR)) return;
		const dirs = readdirSync(BGVIDEO_DIR);
		for (const dir of dirs) {
			const task = loadFromDisk$4(dir);
			if (task) bgVideoTasks.set(task.task_id, task);
		}
	} catch {}
}
//#endregion
//#region server/engines/mv-engine.ts
/**
* MTV 生成引擎 — Host 端核心逻辑
* 管理 MTV 任务的创建、状态、持久化和异步执行。
*
* 功能：
* - 上传音乐/形象
* - 启动生成（谱曲 → 设计 → 分镜 → 视频 → 合成）
* - 查询状态
* - 确认阶段
* - 停止任务
* - 任务列表
*/
const mvTasks = /* @__PURE__ */ new Map();
const MV_DIR = join(dataRoot(), "mv");
function getMvPath(id) {
	const dir = join(MV_DIR, id);
	mkdirSync(dir, { recursive: true });
	return join(dir, "task.json");
}
function saveToDisk$3(task) {
	try {
		writeFileSync(getMvPath(task.task_id), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function loadFromDisk$3(id) {
	try {
		const p = getMvPath(id);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
/**
* 处理 MTV 相关路由。
* @returns null 表示不匹配该路由
*/
async function handleMvRoute(method, path, body, host) {
	const sub = path.slice(20).replace(/^\//, "");
	new URL(`http://dsh.invalid/${sub}`);
	if (method === "GET" && sub === "tasks") return {
		status: 200,
		data: {
			success: true,
			tasks: Array.from(mvTasks.values()).sort((a, b) => b.created_at - a.created_at).slice(0, 20)
		}
	};
	if (method === "POST" && sub === "upload/audio") {
		const { task_id, filename, content } = body;
		if (!content) return {
			status: 400,
			data: { error: "缺少 content（链接、路径或 data URI）" }
		};
		try {
			const t = task_id ? mvTasks.get(String(task_id)) || loadFromDisk$3(String(task_id)) : null;
			const dir = join(MV_DIR, t ? t.task_id : "_uploads");
			mkdirSync(dir, { recursive: true });
			const safe = String(filename || `audio-${Date.now()}.mp3`).replace(/[/\\:*?"<>|]/g, "_");
			const out = join(dir, safe);
			await materialize$1(String(content), out, "音乐");
			if (t) {
				t.audio_file = out;
				t.updated_at = Date.now();
				saveToDisk$3(t);
			}
			return {
				status: 200,
				data: {
					success: true,
					filename: safe,
					path: out
				}
			};
		} catch (e) {
			return {
				status: 500,
				data: { error: e instanceof Error ? e.message : "上传失败" }
			};
		}
	}
	if (method === "POST" && sub === "upload/avatar") {
		const { task_id, filename, content } = body;
		if (!content) return {
			status: 400,
			data: { error: "缺少 content（链接、路径或 data URI）" }
		};
		try {
			const t = task_id ? mvTasks.get(String(task_id)) || loadFromDisk$3(String(task_id)) : null;
			const dir = join(MV_DIR, t ? t.task_id : "_uploads");
			mkdirSync(dir, { recursive: true });
			const safe = String(filename || `avatar-${Date.now()}.jpg`).replace(/[/\\:*?"<>|]/g, "_");
			const out = join(dir, safe);
			await materialize$1(String(content), out, "形象图");
			if (t) {
				t.avatar_file = out;
				t.updated_at = Date.now();
				saveToDisk$3(t);
			}
			return {
				status: 200,
				data: {
					success: true,
					filename: safe,
					path: out
				}
			};
		} catch (e) {
			return {
				status: 500,
				data: { error: e instanceof Error ? e.message : "上传失败" }
			};
		}
	}
	if (method === "POST" && sub === "start") {
		const { audio_file, avatar_file, lyrics, text_model, image_model, video_model, segments } = body;
		if (!audio_file && !lyrics) return {
			status: 400,
			data: { error: "缺少 audio_file 或 lyrics" }
		};
		const taskId = randomUUID().slice(0, 8);
		const task = {
			task_id: taskId,
			status: "music",
			message: "正在谱曲...",
			audio_file,
			avatar_file,
			lyrics,
			text_model: text_model || "agnes-3.0-flash",
			image_model: image_model || "agnes-image-2.5-flash",
			video_model: video_model || "agnes-video-2.5-flash",
			segments: Math.max(3, Math.min(12, segments || 6)),
			created_at: Date.now(),
			updated_at: Date.now()
		};
		mvTasks.set(taskId, task);
		saveToDisk$3(task);
		runMvGeneration(taskId, host).catch(() => {});
		return {
			status: 200,
			data: {
				success: true,
				task_id: taskId
			}
		};
	}
	if (method === "GET" && sub.startsWith("status/")) {
		const taskId = sub.slice(7);
		const task = mvTasks.get(taskId) || loadFromDisk$3(taskId);
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		return {
			status: 200,
			data: {
				success: true,
				task
			}
		};
	}
	if (method === "POST" && sub === "confirm") {
		const { task_id, stage } = body;
		const task = mvTasks.get(task_id || "") || loadFromDisk$3(task_id || "");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		if (stage === "music") {
			task.status = "design";
			task.message = "正在设计...";
		} else if (stage === "design") {
			task.status = "storyboard";
			task.message = "正在生成分镜...";
		} else if (stage === "storyboard") {
			task.status = "video";
			task.message = "正在生成视频...";
		}
		task.updated_at = Date.now();
		saveToDisk$3(task);
		return {
			status: 200,
			data: { success: true }
		};
	}
	if (method === "POST" && sub === "design/regenerate") {
		const { task_id } = body;
		const task = mvTasks.get(task_id || "") || loadFromDisk$3(task_id || "");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		task.status = "design";
		task.message = "正在重新设计...";
		task.updated_at = Date.now();
		saveToDisk$3(task);
		return {
			status: 200,
			data: { success: true }
		};
	}
	if (method === "POST" && sub === "stop") {
		const { task_id } = body;
		const task = mvTasks.get(task_id || "");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		task.status = "stopped";
		task.message = "已停止";
		task.updated_at = Date.now();
		saveToDisk$3(task);
		return {
			status: 200,
			data: { success: true }
		};
	}
	if (method === "GET" && sub.startsWith("file/")) {
		const segs = sub.slice(5).split("/").filter((x) => x && x !== "." && x !== "..");
		const target = join(MV_DIR, ...segs);
		if (!segs.length || !existsSync(target)) return {
			status: 404,
			data: { error: "文件不存在" }
		};
		return {
			status: 200,
			data: {
				success: true,
				rel: segs.join("/"),
				file: segs[segs.length - 1]
			}
		};
	}
	return null;
}
/** 调一次文本模型。 */
async function callChat$1(host, model, system, user, maxTokens = 2e3) {
	const text = (await host.call(getVendorFromModel(model), "/v1/chat/completions", {
		method: "POST",
		body: {
			model,
			messages: [{
				role: "system",
				content: system
			}, {
				role: "user",
				content: user
			}],
			temperature: .8,
			max_tokens: maxTokens
		},
		timeoutMs: 3e5
	}))?.choices?.[0]?.message?.content;
	if (!text || !String(text).trim()) throw new Error("模型没有返回内容（检查 Key 与模型名）");
	return String(text);
}
/** 从模型输出里抠 JSON 数组。 */
function extractJsonArray$1(raw) {
	const s = String(raw);
	const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
	const body = fence ? fence[1] : s;
	const a = body.indexOf("[");
	const b = body.lastIndexOf("]");
	if (a < 0 || b <= a) return [];
	try {
		const arr = JSON.parse(body.slice(a, b + 1));
		return Array.isArray(arr) ? arr : [];
	} catch {
		return [];
	}
}
/**
* 把一份素材落到本地：支持 data URI、http(s) 链接、服务器本地路径。
*/
async function materialize$1(src, outFile, kind) {
	const s = String(src || "").trim();
	if (!s) throw new Error(`缺少${kind}来源`);
	if (s.startsWith("data:")) {
		const b64 = s.slice(s.indexOf(",") + 1);
		if (!b64) throw new Error(`${kind}的 data URI 是空的`);
		writeFileSync(outFile, Buffer.from(b64, "base64"));
		return outFile;
	}
	if (/^https?:\/\//i.test(s)) {
		const resp = await fetch(s, { signal: AbortSignal.timeout(6e5) });
		if (!resp.ok) throw new Error(`${kind}下载失败：HTTP ${resp.status}`);
		const buf = Buffer.from(await resp.arrayBuffer());
		if (!buf.length) throw new Error(`${kind}下载到的是空文件`);
		writeFileSync(outFile, buf);
		return outFile;
	}
	if (!existsSync(s)) throw new Error(`${kind}文件不存在：${s}`);
	return s;
}
/** 生成一张图并落盘。 */
async function genImage(host, model, prompt, outFile) {
	const data = await host.call(getVendorFromModel(model), "/v1/images/generations", {
		method: "POST",
		body: {
			model,
			prompt,
			size: "1024x1024",
			extra_body: { response_format: "url" }
		},
		timeoutMs: 3e5
	});
	const first = Array.isArray(data?.data) ? data.data[0] : null;
	const url = first?.url || (first?.b64_json ? `data:image/png;base64,${first.b64_json}` : "");
	if (!url) throw new Error("生图接口没有返回图片（检查图像模型与 Key）");
	await materialize$1(String(url), outFile, "画面");
}
async function runMvGeneration(taskId, host) {
	const task = mvTasks.get(taskId);
	if (!task) return;
	const textModel = task.text_model || "agnes-3.0-flash";
	const imageModel = task.image_model || "agnes-image-2.5-flash";
	try {
		const dir = join(MV_DIR, taskId);
		mkdirSync(dir, { recursive: true });
		task.dir = dir;
		let audioPath = "";
		if (task.audio_file) {
			task.status = "music";
			task.message = "正在准备音乐…";
			task.updated_at = Date.now();
			saveToDisk$3(task);
			const ext = /\.(wav|m4a|aac|flac|ogg)(\?|$)/i.test(String(task.audio_file)) ? RegExp.$1.toLowerCase() : "mp3";
			audioPath = await materialize$1(String(task.audio_file), join(dir, `audio.${ext}`), "音乐");
		}
		task.status = "design";
		task.message = "正在拆分镜…";
		task.updated_at = Date.now();
		saveToDisk$3(task);
		const n = Math.max(3, Math.min(12, task.segments || 6));
		let scenes = extractJsonArray$1(await callChat$1(host, textModel, "你是 MV 导演，擅长把歌词拆成有画面感、彼此连贯的镜头。", [
			`把下面这首歌的歌词 / 主题拆成 ${n} 个镜头。`,
			"每个镜头给一句可直接用于生图的中文描述：画面主体 + 场景 + 光线 + 构图 + 风格。",
			"镜头之间要有推进感（起—承—转—合），不要每个镜头都同样景别。",
			"只输出 JSON 数组：[{\"scene\":\"画面描述\"}]，不要任何解释。",
			"",
			"【歌词 / 主题】",
			String(task.lyrics || "（没有歌词，请按音乐情绪自由发挥）").slice(0, 4e3)
		].join("\n"), 2500)).map((x) => String(x.scene || "").trim()).filter(Boolean);
		if (!scenes.length) throw new Error("模型没有给出可用的分镜");
		scenes = scenes.slice(0, n);
		task.scenes = scenes;
		task.updated_at = Date.now();
		saveToDisk$3(task);
		const images = [];
		for (let i = 0; i < scenes.length; i++) {
			task.status = "image";
			task.message = `正在生成第 ${i + 1}/${scenes.length} 张画面…`;
			task.updated_at = Date.now();
			saveToDisk$3(task);
			const out = join(dir, `scene_${String(i + 1).padStart(2, "0")}.jpg`);
			await genImage(host, imageModel, scenes[i], out);
			images.push(out);
			task.images = images.slice();
			saveToDisk$3(task);
		}
		let total = 0;
		if (audioPath) {
			const info = await probeMedia(audioPath);
			total = Number(info.duration || 0);
		}
		if (!(total > 0)) total = images.length * 4;
		const per = Math.max(1.5, total / images.length);
		task.status = "video";
		task.message = "正在合成片段…";
		task.updated_at = Date.now();
		saveToDisk$3(task);
		const clips = [];
		for (let i = 0; i < images.length; i++) {
			task.message = `正在合成第 ${i + 1}/${images.length} 段…`;
			task.updated_at = Date.now();
			saveToDisk$3(task);
			const clip = join(dir, `clip_${String(i + 1).padStart(2, "0")}.mp4`);
			const r = await imageToVideo(images[i], clip, per, {
				width: 1280,
				height: 720
			});
			if (!r.ok) throw new Error("合成片段失败：" + (r.error || ""));
			clips.push(clip);
		}
		task.message = "正在拼接…";
		task.updated_at = Date.now();
		saveToDisk$3(task);
		const merged = join(dir, "merged.mp4");
		const cat = await concatVideos(clips, merged, { reencode: true });
		if (!cat.ok) throw new Error("拼接失败：" + (cat.error || ""));
		let note = "";
		if (audioPath) {
			task.message = "正在配乐…";
			task.updated_at = Date.now();
			saveToDisk$3(task);
			const final = join(dir, "final.mp4");
			const mux = await muxNarration({
				visualInput: merged,
				audioInput: audioPath,
				output: final
			});
			if (mux.ok) task.video_id = "final.mp4";
			else {
				task.video_id = "merged.mp4";
				note = "（配乐失败，成片无音轨：" + (mux.error || "") + "）";
			}
		} else {
			task.video_id = "merged.mp4";
			note = "（没有提供音乐，成片无音轨）";
		}
		task.status = "completed";
		task.message = `成片完成：${images.length} 个镜头，每段约 ${per.toFixed(1)} 秒 ${note}`;
		task.updated_at = Date.now();
		saveToDisk$3(task);
	} catch (e) {
		task.status = "failed";
		task.error = e instanceof Error ? e.message : String(e);
		task.message = "生成失败：" + task.error;
		task.updated_at = Date.now();
		saveToDisk$3(task);
	}
}
function rehydrateMvTasks() {
	try {
		if (!existsSync(MV_DIR)) return;
		const dirs = readdirSync(MV_DIR);
		for (const dir of dirs) {
			const task = loadFromDisk$3(dir);
			if (task) mvTasks.set(task.task_id, task);
		}
	} catch {}
}
//#endregion
//#region server/engines/novel-split-engine.ts
/**
* 分批拆分 + 去 AI 味引擎 — Host 端核心逻辑
* 管理拆分任务和去 AI 味任务的创建、状态、持久化和异步执行。
*/
const splitTasks = /* @__PURE__ */ new Map();
const deaiTasks = /* @__PURE__ */ new Map();
const NOVEL_DIR = join(dataRoot(), "novel");
function saveToDisk$2(task, type) {
	try {
		const dir = join(NOVEL_DIR, type === "split" ? "split" : "deai");
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, `${task.id}.json`), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function loadFromDisk$2(id, type) {
	try {
		const dir = join(NOVEL_DIR, type === "split" ? "split" : "deai");
		const p = join(dir, `${id}.json`);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
/**
* 处理分批拆分相关路由。
*/
async function handleNovelSplitRoute(method, path, body, host) {
	const rawSub = path.slice(29).replace(/^\//, "");
	let sub = rawSub;
	try {
		sub = decodeURIComponent(rawSub);
	} catch {
		sub = rawSub;
	}
	new URL(`http://dsh.invalid/${encodeURI(sub)}`);
	if (method === "POST" && sub === "import") {
		const { id } = body;
		if (!id) return {
			status: 400,
			data: { error: "缺少 id" }
		};
		const t = splitTasks.get(id) || loadFromDisk$2(id, "split");
		if (!t) return {
			status: 404,
			data: { error: "找不到这个任务" }
		};
		const text = String(t.source || "");
		return {
			status: 200,
			data: {
				success: true,
				text,
				title: t.title || id,
				words: text.length,
				n_eps: t.n_eps
			}
		};
	}
	if (method === "POST" && sub === "start") {
		const { source, n_eps, model, title } = body;
		if (!source) return {
			status: 400,
			data: { error: "缺少 source" }
		};
		const id = randomUUID().slice(0, 8);
		const task = {
			id,
			status: "running",
			message: "正在拆分...",
			source,
			n_eps: n_eps || 10,
			eps: 0,
			words: 0,
			title: title || "",
			model: model || "agnes-3.0-flash",
			created_at: Date.now(),
			updated_at: Date.now()
		};
		splitTasks.set(id, task);
		saveToDisk$2(task, "split");
		runSplit(id, host).catch(() => {});
		return {
			status: 200,
			data: {
				success: true,
				id,
				note: "已开始拆分"
			}
		};
	}
	if (method === "GET" && sub.startsWith("status/")) {
		const id = sub.slice(7);
		const task = splitTasks.get(id) || loadFromDisk$2(id, "split");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		return {
			status: 200,
			data: {
				success: true,
				task
			}
		};
	}
	if (method === "POST" && sub.startsWith("stop/")) {
		const id = sub.slice(5);
		const task = splitTasks.get(id);
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		task.status = "stopped";
		task.message = "已停止";
		task.updated_at = Date.now();
		saveToDisk$2(task, "split");
		return {
			status: 200,
			data: { success: true }
		};
	}
	if (method === "POST" && sub === "save") {
		const { text, name } = body;
		if (!text || !name) return {
			status: 400,
			data: { error: "缺少 text 或 name" }
		};
		try {
			const safe = String(name).replace(/[/\\:*?"<>|]/g, "_");
			const dir = join(NOVEL_DIR, "saved");
			mkdirSync(dir, { recursive: true });
			const file = safe.endsWith(".md") ? safe : `${safe}.md`;
			writeFileSync(join(dir, file), String(text), "utf8");
			return {
				status: 200,
				data: {
					success: true,
					file,
					rel: `saved/${file}`,
					words: String(text).length
				}
			};
		} catch (e) {
			return {
				status: 500,
				data: { error: e instanceof Error ? e.message : "保存失败" }
			};
		}
	}
	if (method === "POST" && sub === "upload") {
		const { filename, text, title } = body;
		if (!filename) return {
			status: 400,
			data: { error: "缺少 filename" }
		};
		try {
			const safe = String(filename).replace(/[/\\:*?"<>|]/g, "_");
			const dir = join(NOVEL_DIR, "sources");
			mkdirSync(dir, { recursive: true });
			writeFileSync(join(dir, safe), String(text ?? ""), "utf8");
			return {
				status: 200,
				data: {
					success: true,
					filename: safe,
					title: title || safe,
					words: String(text ?? "").length
				}
			};
		} catch (e) {
			return {
				status: 500,
				data: { error: e instanceof Error ? e.message : "上传失败" }
			};
		}
	}
	if (method === "GET" && sub === "files") {
		const files = [];
		try {
			const scan = (dir, prefix) => {
				if (!existsSync(dir)) return;
				for (const name of readdirSync(dir)) {
					const child = join(dir, name);
					try {
						const st = statSync(child);
						if (st.isDirectory()) scan(child, `${prefix}${name}/`);
						else if (st.isFile()) files.push({
							file: name,
							rel: `${prefix}${name}`,
							mtime: new Date(st.mtimeMs).toISOString(),
							size: st.size
						});
					} catch {}
				}
			};
			scan(join(NOVEL_DIR, "split"), "");
			scan(join(NOVEL_DIR, "saved"), "saved/");
		} catch {}
		return {
			status: 200,
			data: {
				success: true,
				files
			}
		};
	}
	if (method === "GET" && sub.startsWith("file/")) {
		const rest = sub.slice(5);
		try {
			const segs = rest.split("/").filter((s) => s && s !== "." && s !== "..");
			const p = join(NOVEL_DIR, ...segs);
			if (!existsSync(p) || !statSync(p).isFile()) return {
				status: 404,
				data: { error: "文件不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					name: rest,
					content: readFileSync(p, "utf8")
				}
			};
		} catch (e) {
			return {
				status: 500,
				data: { error: e instanceof Error ? e.message : "读取失败" }
			};
		}
	}
	return null;
}
/**
* 处理去 AI 味相关路由。
*/
async function handleDeaiRoute(method, path, body, host) {
	const sub = path.slice(22).replace(/^\//, "");
	if (method === "POST" && sub === "process") {
		const { text, op, model } = body;
		if (!text) return {
			status: 400,
			data: { error: "缺少 text" }
		};
		const id = randomUUID().slice(0, 8);
		const task = {
			id,
			status: "running",
			message: "正在处理...",
			text,
			op: op || "medium",
			model: model || "agnes-3.0-flash",
			created_at: Date.now(),
			updated_at: Date.now()
		};
		deaiTasks.set(id, task);
		saveToDisk$2(task, "deai");
		runDeai(id, host).catch(() => {});
		return {
			status: 200,
			data: {
				success: true,
				tid: id
			}
		};
	}
	if (method === "GET" && sub.startsWith("status/")) {
		const id = sub.slice(7);
		const task = deaiTasks.get(id) || loadFromDisk$2(id, "deai");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		return {
			status: 200,
			data: {
				success: true,
				status: task.status,
				message: task.message,
				done: 1,
				total: 1,
				text: task.result
			}
		};
	}
	return null;
}
/**
* 一次喂给模型的最大原文字数。
*
* 超过这个长度就不让模型直接切（上下文塞不下、也容易截断丢内容），
* 改为「按段落保真均分 + 让模型逐集起标题」——切分永远不丢字。
*/
const MODEL_TEXT_LIMIT = 24e3;
/** 去 AI 味规则（服务端任务版，与创作台那份同源）。 */
const DEAI_RULES = [
	"严禁以下 AI 腔，出现即修：",
	"1. \"不是A，而是B\"句式（含省略\"而\"的变体）——直接写 B。",
	"2. 跨段\"不是A。/也不是B。/只是C。\"——压成 C。",
	"3. \"，带着一丝……\"这类万能状语——删状语或换具体动作。",
	"4. 无情绪声线（\"声音不大，却带着……\"\"听不出情绪\"）——直接写台词内容或动作。",
	"5. \"他知道/她知道……\"——用行为展示认知。",
	"6. \"仿佛/犹如/宛若……一般\"——删或白描。",
	"7. \"眼中闪过……\"\"嘴角勾起……\"\"心中一动\"\"心头一震\"——删，改写动作或台词。",
	"8. 章末\"他不知道的是……\"——换成具体的钩子物件或事件。",
	"9. 破折号 —— / —、双连字符 --、用省略号做停顿：一律改用句号、逗号或短句。",
	"10. 禁用词：仿佛、犹如、宛若、一丝、一抹、些许、几分、隐约、深吸一口气、不禁、瞳孔一缩、指节泛白、不由得、不容置疑、显而易见、前所未有、深邃、凛冽、冰冷、情不自禁、话锋一转。",
	"",
	"不能碰的：事实、剧情、人物关系、数字、专有名词一律不许改；不要改人名地名；总字数与原文接近（±15%）。"
].join("\n");
/** 调一次对话模型，返回正文文本。 */
async function callChat(host, model, system, user, maxTokens = 4e3) {
	const vendor = getVendorFromModel(model);
	const text = (await host.call(vendor, "/v1/chat/completions", {
		method: "POST",
		body: {
			model,
			messages: [{
				role: "system",
				content: system
			}, {
				role: "user",
				content: user
			}],
			temperature: .6,
			max_tokens: maxTokens
		},
		timeoutMs: 3e5
	}))?.choices?.[0]?.message?.content;
	if (!text || !String(text).trim()) throw new Error("模型没有返回内容（检查 Key、模型名与额度）");
	return String(text);
}
/** 从模型输出里抠 JSON 数组，容忍 ```json 包裹与前后废话。 */
function extractJsonArray(raw) {
	const s = String(raw);
	const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
	const body = fence ? fence[1] : s;
	const start = body.indexOf("[");
	const end = body.lastIndexOf("]");
	if (start < 0 || end <= start) return null;
	try {
		const arr = JSON.parse(body.slice(start, end + 1));
		return Array.isArray(arr) ? arr : null;
	} catch {
		return null;
	}
}
/** 按段落边界把长文均分成 n 段（保真：只切片，一个字都不改）。 */
function splitByParagraphs(text, n) {
	const raw = String(text);
	const paras = raw.split(/\n+/).map((s) => s.trim()).filter(Boolean);
	if (paras.length === 0) return [raw];
	const per = Math.ceil(raw.length / n);
	const out = [];
	let buf = "";
	for (const p of paras) {
		if (buf.length > 0 && out.length < n - 1 && buf.length + p.length > per) {
			out.push(buf);
			buf = "";
		}
		buf += (buf ? "\n\n" : "") + p;
	}
	if (buf.trim()) out.push(buf);
	while (out.length < n) out.push("");
	return out.slice(0, n);
}
/** 把标题清洗成安全文件名片段。 */
function safeName$1(s) {
	return String(s || "").replace(/[/\\:*?"<>|]/g, "_").slice(0, 40);
}
async function runSplit(id, host) {
	const task = splitTasks.get(id);
	if (!task) return;
	const n = Math.max(1, Math.min(200, task.n_eps || 10));
	const model = task.model || "agnes-3.0-flash";
	try {
		task.status = "running";
		task.message = "正在读取原文…";
		task.updated_at = Date.now();
		saveToDisk$2(task, "split");
		const text = String(task.source || "");
		if (!text.trim()) throw new Error("原文是空的");
		const total = text.length;
		let pieces = [];
		let titles = [];
		if (total <= MODEL_TEXT_LIMIT) {
			task.message = "正在让模型按情节分集…";
			task.updated_at = Date.now();
			saveToDisk$2(task, "split");
			const arr = extractJsonArray(await callChat(host, model, "你是网文编辑，擅长按情节断点把长文切成连载单元。", [
				`下面是一篇小说全文，约 ${total} 字。请按情节把它切成 ${n} 集。`,
				"",
				"要求：",
				"1. 只在情节断点处切（场景转换、时间跳跃、冲突收束），不要机械按字数。",
				"2. 每集的 content 必须逐字来自原文，不许改写、不许增删、不许润色。",
				"3. 每集给一个 4–12 字的标题，要能勾起兴趣。",
				"4. 只输出 JSON 数组，格式：[{\"title\":\"标题\",\"content\":\"原文片段\"}]，不要任何解释。",
				"",
				"【原文开始】",
				text,
				"【原文结束】"
			].join("\n"), 8e3));
			if (arr) for (const it of arr) {
				const t = String(it?.title ?? "").trim();
				const c = String(it?.content ?? "").trim();
				if (c) {
					pieces.push(c);
					titles.push(t || `第 ${pieces.length} 集`);
				}
			}
		}
		if (!pieces.length) {
			task.message = `原文较长，按段落切 ${n} 集…`;
			task.updated_at = Date.now();
			saveToDisk$2(task, "split");
			pieces = splitByParagraphs(text, n);
			titles = pieces.map((_, i) => `第 ${i + 1} 集`);
		}
		while (pieces.length < n) pieces.push("");
		pieces = pieces.slice(0, n);
		while (titles.length < pieces.length) titles.push(`第 ${titles.length + 1} 集`);
		if (titles.every((t) => /^第 \d+ 集$/.test(t)) && pieces.some((p) => p.trim())) {
			task.message = "正在给每集起标题…";
			task.updated_at = Date.now();
			saveToDisk$2(task, "split");
			try {
				const heads = pieces.map((p, i) => `【第${i + 1}集开头】${p.slice(0, 180)}`).join("\n\n");
				const arr = extractJsonArray(await callChat(host, model, "你是网文编辑，擅长给章节起有钩子的短标题。", `下面是同一篇小说的 ${pieces.length} 集开头。请给每集起一个 4–12 字的标题。\n只输出 JSON 数组：[{"t":"标题"}]，顺序与集号一致，不要解释。\n\n${heads}`, 2e3));
				if (arr) for (let i = 0; i < pieces.length && i < arr.length; i++) {
					const t = String(arr[i]?.t ?? arr[i]?.title ?? "").trim();
					if (t) titles[i] = t;
				}
			} catch {}
		}
		task.episodes = pieces.map((c, i) => ({
			ep: i + 1,
			title: titles[i] || `第 ${i + 1} 集`,
			content: c
		}));
		task.eps = task.episodes.length;
		task.words = total;
		try {
			const dir = join(NOVEL_DIR, "split", id);
			mkdirSync(dir, { recursive: true });
			for (const ep of task.episodes) {
				if (!ep.content.trim()) continue;
				const fname = `EP${String(ep.ep).padStart(3, "0")}-${safeName$1(ep.title)}.md`;
				writeFileSync(join(dir, fname), `# ${ep.title}\n\n${ep.content}\n`, "utf8");
			}
		} catch {}
		task.status = "completed";
		task.message = `拆分完成，共 ${task.episodes.length} 集`;
		task.updated_at = Date.now();
		saveToDisk$2(task, "split");
	} catch (e) {
		task.status = "failed";
		task.error = e instanceof Error ? e.message : String(e);
		task.message = `拆分失败：${task.error}`;
		task.updated_at = Date.now();
		saveToDisk$2(task, "split");
	}
}
async function runDeai(id, host) {
	const task = deaiTasks.get(id);
	if (!task) return;
	const model = task.model || "agnes-3.0-flash";
	try {
		task.status = "running";
		task.message = "正在处理…";
		task.updated_at = Date.now();
		saveToDisk$2(task, "deai");
		const level = task.op === "light" ? "只替换禁用词与标点，尽量不改句式结构。" : task.op === "heavy" ? "可以重写句子、拆句并句，但事实、情节、人物关系一个都不能变。" : "删除禁用词，并改写命中清单的句式；句子结构可小幅调整。";
		const text = String(task.text || "");
		const LIMIT = 12e3;
		const body = text.length > LIMIT ? text.slice(0, LIMIT) : text;
		const note = text.length > LIMIT ? `\n（原文较长，本次只处理前 ${LIMIT} 字）` : "";
		const raw = await callChat(host, model, `你是中文网文的文字编辑，任务是把 AI 腔改成人话。你只改表达，绝不改事实。\n\n${DEAI_RULES}`, `按这个力度处理正文：${level}\n\n只输出处理后的完整正文，前后不要加任何说明、标题或总结。保留原有段落结构。${note}\n\n【原文开始】\n${body}\n【原文结束】`, 8e3);
		task.result = raw;
		task.status = "completed";
		task.message = `处理完成（${raw.length} 字）`;
		task.updated_at = Date.now();
		saveToDisk$2(task, "deai");
	} catch (e) {
		task.status = "failed";
		task.message = `处理失败：${e instanceof Error ? e.message : String(e)}`;
		task.updated_at = Date.now();
		saveToDisk$2(task, "deai");
	}
}
function rehydrateNovelSplit() {
	try {
		const splitDir = join(NOVEL_DIR, "split");
		if (existsSync(splitDir)) {
			const dirs = readdirSync(splitDir);
			for (const dir of dirs) {
				const task = loadFromDisk$2(dir, "split");
				if (task) splitTasks.set(task.id, task);
			}
		}
		const deaiDir = join(NOVEL_DIR, "deai");
		if (existsSync(deaiDir)) {
			const dirs = readdirSync(deaiDir);
			for (const dir of dirs) {
				const task = loadFromDisk$2(dir, "deai");
				if (task) deaiTasks.set(task.id, task);
			}
		}
	} catch {}
}
//#endregion
//#region server/engines/local-tts.ts
/**
* 本地离线配音（espeak-ng）—— 保底方案。
*
* ═══════════════════════════════════════════════════════════════════════
* 为什么做这个
*
* 语音是本站唯一必须额外配一家 Key 的能力（Agnes 没有音频模型）。
* 但很多人只是想先听听效果、不想为配音再注册一家——所以给一个
* **不花钱、不联网、不填 Key** 的本地引擎打底。
*
* 音质说明（要对使用者说实话）：espeak-ng 是共振峰合成，
* 吐字清楚可懂，但**明显是机器音**，多音字和语调也不够准。
* 定位是「先能用」，不是「能上正式作品」。
* 想要自然的人声，还是用 MiniMax / MiMo。
* ═══════════════════════════════════════════════════════════════════════
*/
const execFileAsync$2 = promisify(execFile);
/** 找 espeak-ng 可执行文件。 */
function findEspeak() {
	for (const p of [
		"/usr/bin/espeak-ng",
		"/usr/local/bin/espeak-ng",
		"/bin/espeak-ng",
		"/usr/bin/espeak"
	]) if (existsSync(p)) return p;
	return null;
}
/** 本机是否具备离线配音能力。 */
function localTtsStatus() {
	if (!findEspeak()) return {
		available: false,
		engine: null,
		note: "本机没有 espeak-ng。想用免费离线配音，在服务器上装一个即可：apt-get install espeak-ng（Debian/Ubuntu）或 apk add espeak-ng（Alpine）。"
	};
	return {
		available: true,
		engine: "espeak-ng",
		note: "本地离线配音可用。吐字清楚但明显是机器音——适合先试用，正式作品建议用 MiniMax / MiMo。"
	};
}
/**
* 用 espeak-ng 合成一段中文语音。
*
* @param text 要读的文字
* @param outFile 输出文件（会统一转成 wav，便于后续拼接）
* @param opts.speed 语速，默认 150（约等于正常语速）
*/
async function synthesizeLocal(text, outFile, opts = {}) {
	const bin = findEspeak();
	if (!bin) return {
		ok: false,
		error: "本机没有 espeak-ng：请先安装（apt-get install espeak-ng）"
	};
	const clean = String(text || "").replace(/\s+/g, " ").trim();
	if (!clean) return {
		ok: false,
		error: "没有要朗读的文字"
	};
	const tmp = outFile.replace(/\.wav$/i, "") + ".raw.wav";
	try {
		await execFileAsync$2(bin, [
			"-v",
			"cmn",
			"-s",
			String(opts.speed || 150),
			"-w",
			tmp,
			clean
		], {
			timeout: 12e4,
			maxBuffer: 8 << 20
		});
		if (!existsSync(tmp) || statSync(tmp).size < 1e3) return {
			ok: false,
			error: "espeak-ng 没有产出有效音频（文字里可能没有任何可读内容）"
		};
		const r = await ffmpeg$1([
			"-y",
			"-i",
			tmp,
			"-ar",
			"16000",
			"-ac",
			"1",
			outFile
		], 6e4);
		rmSync(tmp, { force: true });
		if (!r.ok || !existsSync(outFile)) return {
			ok: false,
			error: "转码失败：" + (r.error || "")
		};
		const info = await probeMedia(outFile);
		return {
			ok: true,
			duration: Number(info.duration || 0)
		};
	} catch (e) {
		rmSync(tmp, { force: true });
		return {
			ok: false,
			error: e instanceof Error ? e.message : String(e)
		};
	}
}
//#endregion
//#region server/engines/toolbox-engine.ts
/**
* 多能宝箱引擎 — Host 端核心逻辑
* 提供视频下载和文本转音频功能。
*/
const execFileAsync$1 = promisify(execFile);
const vidbeeTasks = /* @__PURE__ */ new Map();
const TOOLBOX_DIR = join(dataRoot(), "toolbox");
function getToolboxPath(id) {
	const dir = join(TOOLBOX_DIR, "vidbee");
	mkdirSync(dir, { recursive: true });
	return join(dir, `${id}.json`);
}
function saveToDisk$1(task) {
	try {
		writeFileSync(getToolboxPath(task.task_id), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function loadFromDisk$1(id) {
	try {
		const p = getToolboxPath(id);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
/**
* 处理多能宝箱相关路由。
*/
async function handleToolboxRoute(method, path, body, host) {
	const rest = path.slice(25).replace(/^\//, "");
	const sub = rest.split("?")[0];
	const url = new URL(`http://dsh.invalid/${rest}`);
	if (method === "POST" && sub === "vidbee/download") {
		const { url, quality } = body;
		if (!url) return {
			status: 400,
			data: { error: "缺少 url" }
		};
		const id = randomUUID().slice(0, 8);
		const task = {
			task_id: id,
			url,
			quality: quality || "best",
			status: "running",
			log: ["任务创建..."],
			created_at: Date.now(),
			updated_at: Date.now()
		};
		vidbeeTasks.set(id, task);
		saveToDisk$1(task);
		runVidbee(id, host).catch(() => {});
		return {
			status: 200,
			data: {
				success: true,
				task_id: id
			}
		};
	}
	if (method === "GET" && sub.startsWith("vidbee/status")) {
		const id = url.searchParams.get("task_id") || sub.split("?")[0].split("/").pop() || "";
		const task = vidbeeTasks.get(id) || loadFromDisk$1(id);
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		return {
			status: 200,
			data: {
				success: true,
				status: task.status,
				log: task.log
			}
		};
	}
	if (method === "GET" && sub === "vidbee/list") return {
		status: 200,
		data: {
			success: true,
			items: Array.from(vidbeeTasks.values()).filter((t) => t.status === "done").map((t) => ({
				name: t.name,
				size: t.size,
				url: `/toolbox/vidbee/${t.task_id}`
			}))
		}
	};
	if (method === "POST" && sub === "vidbee/delete") {
		const { name } = body;
		for (const [id, task] of vidbeeTasks) if (task.name === name) {
			vidbeeTasks.delete(id);
			return {
				status: 200,
				data: { success: true }
			};
		}
		return {
			status: 404,
			data: { error: "文件不存在" }
		};
	}
	if (method === "GET" && sub === "tts/engines") {
		const local = localTtsStatus();
		return {
			status: 200,
			data: {
				success: true,
				engines: [{
					id: "local",
					name: "本地离线配音（免费，不用 Key）",
					available: local.available,
					note: local.note,
					quality: "机械音"
				}, {
					id: "minimax",
					name: "MiniMax（声音自然）",
					available: true,
					note: "需要在「设置」里填 MiniMax 的 Key。",
					quality: "自然"
				}]
			}
		};
	}
	if (method === "POST" && sub === "tts") {
		const { text, voice } = body;
		if (!text || !String(text).trim()) return {
			status: 400,
			data: { error: "缺少 text" }
		};
		try {
			const { buf, ext } = await synthTts(host, String(text), String(voice || ""));
			const id = randomUUID().slice(0, 8);
			const dir = join(TOOLBOX_DIR, "tts");
			mkdirSync(dir, { recursive: true });
			const file = `${id}.${ext}`;
			writeFileSync(join(dir, file), buf);
			return {
				status: 200,
				data: {
					success: true,
					id,
					file,
					bytes: buf.length,
					dataUri: `data:audio/${ext === "mp3" ? "mpeg" : ext};base64,${buf.toString("base64")}`
				}
			};
		} catch (e) {
			return {
				status: 500,
				data: { error: e instanceof Error ? e.message : "TTS 失败" }
			};
		}
	}
	if (method === "GET" && sub.startsWith("tts/")) {
		const safe = sub.slice(4).split("/").filter((x) => x && x !== "." && x !== "..").pop() || "";
		const file = join(TOOLBOX_DIR, "tts", safe);
		if (!safe || !existsSync(file)) return {
			status: 404,
			data: { error: "音频不存在" }
		};
		const buf = readFileSync(file);
		const ext = safe.split(".").pop() || "mp3";
		return {
			status: 200,
			data: {
				success: true,
				file: safe,
				bytes: buf.length,
				dataUri: `data:audio/${ext === "mp3" ? "mpeg" : ext};base64,${buf.toString("base64")}`
			}
		};
	}
	return null;
}
/** 从 URL 猜一个安全的文件名。 */
function guessFileName(url) {
	try {
		const u = new URL(url);
		let name = decodeURIComponent(u.pathname.split("/").filter(Boolean).pop() || "");
		if (!name || !/\.[a-z0-9]{2,5}$/i.test(name)) name = "video-" + Date.now() + ".mp4";
		return name.replace(/[/\\:*?"<>|]/g, "_").slice(0, 80);
	} catch {
		return "video-" + Date.now() + ".mp4";
	}
}
/** 找 yt-dlp（支持 B 站 / YouTube 等需要解析的站点）。 */
function resolveYtdlp() {
	for (const p of [
		"/usr/local/bin/yt-dlp",
		"/usr/bin/yt-dlp",
		"/bin/yt-dlp"
	]) if (existsSync(p)) return p;
	return null;
}
/** 目录里最新的一个非 json 文件（yt-dlp 没回报路径时兜底）。 */
function newestArtifact(dir) {
	try {
		const cands = readdirSync(dir).filter((f) => !f.endsWith(".json")).map((f) => {
			try {
				const st = statSync(join(dir, f));
				return st.isFile() ? {
					file: join(dir, f),
					m: st.mtimeMs,
					size: st.size
				} : null;
			} catch {
				return null;
			}
		}).filter(Boolean);
		cands.sort((a, b) => b.m - a.m);
		return cands.length ? {
			file: cands[0].file,
			size: cands[0].size
		} : null;
	} catch {
		return null;
	}
}
async function runVidbee(id, host) {
	const task = vidbeeTasks.get(id);
	if (!task) return;
	try {
		task.status = "running";
		task.log.push("开始处理：" + task.url);
		task.updated_at = Date.now();
		saveToDisk$1(task);
		const dir = join(TOOLBOX_DIR, "vidbee");
		mkdirSync(dir, { recursive: true });
		const ytdlp = resolveYtdlp();
		let done = false;
		if (ytdlp) {
			task.log.push("尝试 yt-dlp（支持各大视频站）");
			task.updated_at = Date.now();
			saveToDisk$1(task);
			try {
				const out = await execFileAsync$1(ytdlp, [
					"--no-playlist",
					"--merge-output-format",
					"mp4",
					"-f",
					"bestvideo*+bestaudio/best",
					"--print",
					"after_move:filepath",
					"-o",
					join(dir, "%(title).70s.%(ext)s"),
					String(task.url)
				], {
					timeout: 18e5,
					maxBuffer: 67108864
				});
				const printed = String(out.stdout || "").split("\n").map((x) => x.trim()).filter(Boolean);
				let file = printed.length ? printed[printed.length - 1] : "";
				if (!file || !existsSync(file)) {
					const fresh = newestArtifact(dir);
					file = fresh ? fresh.file : "";
				}
				if (file && existsSync(file)) {
					task.name = basename(file);
					task.size = statSync(file).size;
					task.log.push(`完成：${task.name}（${(task.size / 1048576).toFixed(1)} MB）`);
					done = true;
				} else task.log.push("yt-dlp 跑完但没找到产物，改走直链下载");
			} catch (e) {
				const msg = e instanceof Error ? e.message : String(e);
				task.log.push("yt-dlp 失败（" + msg.slice(0, 120) + "），改走直链下载");
				task.updated_at = Date.now();
				saveToDisk$1(task);
			}
		} else task.log.push("本机没有 yt-dlp，按直链下载");
		if (!done) {
			const resp = await fetch(String(task.url), { signal: AbortSignal.timeout(9e5) });
			if (!resp.ok) throw new Error(`下载失败：HTTP ${resp.status}`);
			const buf = Buffer.from(await resp.arrayBuffer());
			if (!buf.length) throw new Error("下载到的是空文件");
			const name = guessFileName(String(task.url));
			writeFileSync(join(dir, name), buf);
			task.name = name;
			task.size = buf.length;
			task.log.push(`完成：${name}（${(buf.length / 1048576).toFixed(1)} MB）`);
		}
		task.status = "done";
		task.updated_at = Date.now();
		saveToDisk$1(task);
	} catch (e) {
		task.status = "failed";
		task.log.push("失败：" + (e instanceof Error ? e.message : String(e)));
		task.updated_at = Date.now();
		saveToDisk$1(task);
	}
}
/**
* 文本转语音。
*
* 走 MiniMax（六大厂商之一，用户配了 Key 就能用）。MiMo TTS 那条路只有口播的
* host 暴露了 resolveTtsKey，工具箱这边拿不到，所以不做硬依赖。
*/
async function synthTts(host, text, voice) {
	if (voice === "local" || voice === "espeak") {
		const dir = join(TOOLBOX_DIR, "tts");
		mkdirSync(dir, { recursive: true });
		const out = join(dir, `local-${Date.now().toString(36)}.wav`);
		const r = await synthesizeLocal(String(text), out);
		if (!r.ok) throw new Error(r.error || "本地配音失败");
		return {
			buf: readFileSync(out),
			ext: "wav"
		};
	}
	const hex = (await host.call("minimax", "/v1/t2a_v2", {
		method: "POST",
		body: {
			model: "speech-01-turbo",
			text: String(text).slice(0, 5e3),
			stream: false,
			voice_setting: {
				voice_id: voice || "male-qn-qingse",
				speed: 1,
				vol: 1,
				pitch: 0
			},
			audio_setting: {
				sample_rate: 32e3,
				bitrate: 128e3,
				format: "mp3"
			}
		},
		timeoutMs: 3e5
	}))?.data?.audio;
	if (typeof hex !== "string" || !hex) {
		const local = localTtsStatus();
		throw new Error("MiniMax TTS 没有返回音频：确认已在「设置」里填 MiniMax Key，且账户可用。" + (local.available ? "（也可以把音色切成「本地离线配音」，不填 Key 就能用）" : ""));
	}
	return {
		buf: Buffer.from(hex, "hex"),
		ext: "mp3"
	};
}
function rehydrateToolbox() {
	try {
		const dir = join(TOOLBOX_DIR, "vidbee");
		if (!existsSync(dir)) return;
		const dirs = readdirSync(dir);
		for (const d of dirs) {
			const task = loadFromDisk$1(d.replace(".json", ""));
			if (task) vidbeeTasks.set(task.task_id, task);
		}
	} catch {}
}
//#endregion
//#region server/engines/videoparse-engine.ts
/**
* 视频解析 + VPT 引擎 — Host 端核心逻辑
* 提供视频内容分析、关键帧提取和视频提示词生成功能。
*/
const videoparseTasks = /* @__PURE__ */ new Map();
const vptTasks = /* @__PURE__ */ new Map();
const VIDEOPARSE_DIR = join(dataRoot(), "videoparse");
function getVideoparsePath(id, type) {
	const dir = join(VIDEOPARSE_DIR, type);
	mkdirSync(dir, { recursive: true });
	return join(dir, `${id}.json`);
}
function saveToDisk(task, type) {
	try {
		writeFileSync(getVideoparsePath(task.id, type), JSON.stringify(task, null, 2), "utf8");
	} catch {}
}
function loadFromDisk(id, type) {
	try {
		const p = getVideoparsePath(id, type);
		return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null;
	} catch {
		return null;
	}
}
/**
* 处理视频解析相关路由。
*/
async function handleVideoparseRoute(method, path, body, host) {
	const sub = path.slice(23).replace(/^\//, "");
	if (method === "POST" && sub === "parse") {
		const { video_file, model, vendor, frames } = body;
		if (!video_file) return {
			status: 400,
			data: { error: "缺少 video_file（视频链接，或服务器上的本地路径）" }
		};
		const id = randomUUID().slice(0, 8);
		const task = {
			id,
			status: "running",
			message: "正在解析视频...",
			video_file,
			model: model || "agnes-2.5-flash",
			vendor: vendor || "agnes",
			frames: Math.max(2, Math.min(12, frames || 6)),
			created_at: Date.now(),
			updated_at: Date.now()
		};
		videoparseTasks.set(id, task);
		saveToDisk(task, "parse");
		runVideoparse(id, host).catch(() => {});
		return {
			status: 200,
			data: {
				success: true,
				id
			}
		};
	}
	if (method === "GET" && sub.startsWith("parse/status/")) {
		const id = sub.slice(13);
		const task = videoparseTasks.get(id) || loadFromDisk(id, "parse");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		const out = { ...task };
		if (task.status === "completed" && Array.isArray(task.keyframes)) {
			const dir = join(VIDEOPARSE_DIR, id);
			out.framesData = task.keyframes.map((kf) => {
				try {
					const fp = join(dir, kf);
					return existsSync(fp) ? `data:image/jpeg;base64,${readFileSync(fp).toString("base64")}` : "";
				} catch {
					return "";
				}
			});
		}
		return {
			status: 200,
			data: {
				success: true,
				task: out
			}
		};
	}
	return null;
}
/**
* 处理 VPT 相关路由。
*/
async function handleVptRoute(method, path, body, host) {
	const sub = path.slice(21).replace(/^\//, "");
	if (method === "POST" && sub === "generate") {
		const { video_file, model, vendor } = body;
		if (!video_file) return {
			status: 400,
			data: { error: "缺少 video_file（已解析任务的 id，或一段素材描述）" }
		};
		const id = randomUUID().slice(0, 8);
		const task = {
			id,
			status: "running",
			message: "正在生成提示词...",
			video_file,
			created_at: Date.now(),
			updated_at: Date.now()
		};
		task.model = model || "agnes-2.5-flash";
		task.vendor = vendor || "agnes";
		vptTasks.set(id, task);
		saveToDisk(task, "vpt");
		runVpt(id, host).catch(() => {});
		return {
			status: 200,
			data: {
				success: true,
				id
			}
		};
	}
	if (method === "POST" && sub === "optimize") {
		const { id, prompt } = body;
		const task = vptTasks.get(id) || loadFromDisk(id, "vpt");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		task.optimized_prompt = prompt;
		task.updated_at = Date.now();
		saveToDisk(task, "vpt");
		return {
			status: 200,
			data: { success: true }
		};
	}
	if (method === "GET" && sub.startsWith("status/")) {
		const id = sub.slice(7);
		const task = vptTasks.get(id) || loadFromDisk(id, "vpt");
		if (!task) return {
			status: 404,
			data: { error: "任务不存在" }
		};
		return {
			status: 200,
			data: {
				success: true,
				task
			}
		};
	}
	return null;
}
/** 默认看帧用的多模态模型（必须能读图）。 */
const VISION_MODEL = "agnes-2.5-flash";
/** 本地图片转 data URI，供多模态模型读取。 */
function toDataUri(file) {
	return `data:image/jpeg;base64,${readFileSync(file).toString("base64")}`;
}
/** 调一次对话模型（可带图）。 */
async function callVision(host, vendor, model, messages, maxTokens = 500) {
	const text = (await host.call(vendor, "/v1/chat/completions", {
		method: "POST",
		body: {
			model,
			messages,
			temperature: .4,
			max_tokens: maxTokens
		},
		timeoutMs: 18e4
	}))?.choices?.[0]?.message?.content;
	if (!text || !String(text).trim()) throw new Error("模型没有返回内容（检查 Key，以及该模型是否支持读图）");
	return String(text).trim();
}
async function runVideoparse(id, host) {
	const task = videoparseTasks.get(id);
	if (!task) return;
	const model = task.model || VISION_MODEL;
	const vendor = task.vendor || "agnes";
	const frameCount = Math.max(2, Math.min(12, task.frames || 6));
	try {
		task.status = "running";
		task.message = "准备视频…";
		task.updated_at = Date.now();
		saveToDisk(task, "parse");
		const dir = join(VIDEOPARSE_DIR, id);
		mkdirSync(dir, { recursive: true });
		task.dir = dir;
		const src = String(task.video_file || "").trim();
		let local = src;
		if (/^https?:\/\//i.test(src)) {
			task.message = "正在下载视频…";
			task.updated_at = Date.now();
			saveToDisk(task, "parse");
			const extMatch = src.match(/\.(mp4|mov|mkv|webm|avi|m4v)(?:\?|$)/i);
			local = join(dir, "input." + (extMatch ? extMatch[1].toLowerCase() : "mp4"));
			const resp = await fetch(src, { signal: AbortSignal.timeout(3e5) });
			if (!resp.ok) throw new Error(`下载视频失败：HTTP ${resp.status}`);
			const buf = Buffer.from(await resp.arrayBuffer());
			if (!buf.length) throw new Error("下载到的视频是空的");
			writeFileSync(local, buf);
		} else if (!existsSync(local)) throw new Error(`本地视频不存在：${local}`);
		const info = await probeMedia(local);
		if (!info.ok) throw new Error("ffprobe 读不出这个视频：" + (info.error || "未知原因"));
		const duration = Number(info.duration || 0);
		task.duration = duration;
		const frames = [];
		for (let i = 0; i < frameCount; i++) {
			const t = duration > 0 ? duration * (i + .5) / frameCount : i * 2;
			const out = join(dir, `frame_${String(i + 1).padStart(2, "0")}.jpg`);
			if (!(await ffmpeg$1([
				"-ss",
				t.toFixed(2),
				"-i",
				local,
				"-frames:v",
				"1",
				"-vf",
				"scale=640:-2",
				"-q:v",
				"3",
				out
			], 12e4)).ok || !existsSync(out)) continue;
			frames.push({
				index: frames.length + 1,
				time: Number(t.toFixed(1)),
				file: out,
				description: ""
			});
			task.message = `已抽 ${frames.length}/${frameCount} 帧…`;
			task.updated_at = Date.now();
			saveToDisk(task, "parse");
		}
		if (!frames.length) throw new Error("没能从这个视频里抽出任何帧（格式可能不被 ffmpeg 支持）");
		for (const f of frames) {
			task.message = `正在解读第 ${f.index}/${frames.length} 帧…`;
			task.updated_at = Date.now();
			saveToDisk(task, "parse");
			try {
				f.description = await callVision(host, vendor, model, [{
					role: "user",
					content: [{
						type: "text",
						text: `这是从一段视频里抽出的第 ${f.index} 帧（约第 ${f.time} 秒）。请用一句中文描述：画面里有什么、人物在做什么、景别与光线氛围如何。直接描述，不要客套。`
					}, {
						type: "image_url",
						image_url: { url: toDataUri(f.file) }
					}]
				}], 300);
			} catch (e) {
				f.description = "（这一帧解读失败：" + (e instanceof Error ? e.message : String(e)) + "）";
			}
		}
		task.message = "正在汇总…";
		task.updated_at = Date.now();
		saveToDisk(task, "parse");
		let summary = "";
		try {
			summary = await callVision(host, vendor, model, [{
				role: "user",
				content: `下面是一段视频按时间抽出的帧描述。请用中文写一份不超过 200 字的视频内容索引：说清主体、场景变化与镜头节奏。\n\n${frames.map((f) => `第${f.index}帧(${f.time}s)：${f.description}`).join("\n")}`
			}], 500);
		} catch {}
		task.scenes = frames.map((f) => ({
			index: f.index,
			start: f.time,
			end: f.time,
			description: f.description
		}));
		task.keyframes = frames.map((f) => `frame_${String(f.index).padStart(2, "0")}.jpg`);
		task.summary = summary || frames.map((f) => f.description).join("\n");
		task.status = "completed";
		task.message = `解析完成：${frames.length} 帧，视频约 ${Math.round(duration)} 秒`;
		task.updated_at = Date.now();
		saveToDisk(task, "parse");
	} catch (e) {
		task.status = "failed";
		task.message = e instanceof Error ? e.message : "解析失败";
		task.updated_at = Date.now();
		saveToDisk(task, "parse");
	}
}
async function runVpt(id, host) {
	const task = vptTasks.get(id);
	if (!task) return;
	const model = task.model || VISION_MODEL;
	const vendor = task.vendor || "agnes";
	try {
		task.status = "running";
		task.message = "正在生成提示词…";
		task.updated_at = Date.now();
		saveToDisk(task, "vpt");
		const ref = String(task.video_file || "").trim();
		let material = ref;
		const parsed = videoparseTasks.get(ref) || loadFromDisk(ref, "parse");
		if (parsed && Array.isArray(parsed.scenes) && parsed.scenes.length) {
			material = parsed.scenes.map((s) => `第${s.index}帧(${s.start}s)：${s.description}`).join("\n");
			if (parsed.summary) material = `【内容索引】\n${parsed.summary}\n\n【逐帧】\n${material}`;
		}
		task.prompt = await callVision(host, vendor, model, [{
			role: "user",
			content: [
				"你是短视频导演。根据下面的素材，写一组可直接喂给「图生视频 / 文生视频」模型的中文提示词。",
				"每条按「起始状态 + 动作过程 + 运镜 + 时长」组织，一条只描述一个连续镜头。",
				"只输出提示词本身，一行一条，不要解释。",
				"",
				"【素材】",
				material
			].join("\n")
		}], 1200);
		task.status = "completed";
		task.message = "提示词已生成";
		task.updated_at = Date.now();
		saveToDisk(task, "vpt");
	} catch (e) {
		task.status = "failed";
		task.message = e instanceof Error ? e.message : "生成失败";
		task.updated_at = Date.now();
		saveToDisk(task, "vpt");
	}
}
function rehydrateVideoparse() {
	try {
		const parseDir = join(VIDEOPARSE_DIR, "parse");
		if (existsSync(parseDir)) {
			const dirs = readdirSync(parseDir);
			for (const d of dirs) {
				const task = loadFromDisk(d.replace(".json", ""), "parse");
				if (task) videoparseTasks.set(task.id, task);
			}
		}
		const vptDir = join(VIDEOPARSE_DIR, "vpt");
		if (existsSync(vptDir)) {
			const dirs = readdirSync(vptDir);
			for (const d of dirs) {
				const task = loadFromDisk(d.replace(".json", ""), "vpt");
				if (task) vptTasks.set(task.id, task);
			}
		}
	} catch {}
}
//#endregion
//#region server/engines/wechat-engine.ts
/**
* 微信公众号 + 本地文件引擎 — Host 端核心逻辑
* 提供公众号文章生成、排版、发布和本地文件管理功能。
*/
const wechatArticles = /* @__PURE__ */ new Map();
join(dataRoot(), "wechat");
const WECHAT_CONFIG_FILE = join(dataRoot(), "wechat-config.json");
/**
* 公众号凭据。AppID 可明文回显；AppSecret 只回「是否已配置」，不回传明文。
*/
const wechatConfig = {
	appid: "",
	secret: ""
};
function loadWechatConfig() {
	try {
		if (!existsSync(WECHAT_CONFIG_FILE)) return;
		const raw = JSON.parse(readFileSync(WECHAT_CONFIG_FILE, "utf8"));
		wechatConfig.appid = String(raw.appid ?? "");
		wechatConfig.secret = String(raw.secret ?? "");
	} catch {}
}
function saveWechatConfig() {
	try {
		mkdirSync(dataRoot(), { recursive: true });
		writeFileSync(WECHAT_CONFIG_FILE, JSON.stringify({
			appid: wechatConfig.appid,
			secret: wechatConfig.secret
		}), "utf8");
	} catch {}
}
const LOCALFILES_DIR = join(dataRoot(), "localfiles");
/**
* 处理微信公众号相关路由。
*/
async function handleWechatRoute(method, path, body, host) {
	const sub = path.slice(24).replace(/^\//, "");
	if (method === "GET" && sub === "config") return {
		status: 200,
		data: {
			success: true,
			appid: wechatConfig.appid,
			has_secret: wechatConfig.secret.length > 0
		}
	};
	if (method === "POST" && sub === "config") {
		const { appid, secret } = body;
		if (typeof appid === "string") wechatConfig.appid = appid.trim();
		if (typeof secret === "string" && secret.trim().length > 0) wechatConfig.secret = secret.trim();
		saveWechatConfig();
		return {
			status: 200,
			data: {
				success: true,
				appid: wechatConfig.appid,
				has_secret: wechatConfig.secret.length > 0
			}
		};
	}
	if (method === "POST" && sub === "article") {
		const { title, content, author } = body;
		if (!title || !content) return {
			status: 400,
			data: { error: "缺少 title 或 content" }
		};
		const id = randomUUID().slice(0, 8);
		const article = {
			id,
			title,
			content,
			author: author || "AI 助手",
			status: "draft",
			created_at: Date.now(),
			updated_at: Date.now()
		};
		wechatArticles.set(id, article);
		return {
			status: 200,
			data: {
				success: true,
				article
			}
		};
	}
	if (method === "POST" && sub === "publish") {
		const { id } = body;
		const article = wechatArticles.get(id);
		if (!article) return {
			status: 404,
			data: { error: "文章不存在" }
		};
		article.status = "published";
		article.updated_at = Date.now();
		return {
			status: 200,
			data: {
				success: true,
				article
			}
		};
	}
	if (method === "GET" && sub === "list") return {
		status: 200,
		data: {
			success: true,
			articles: Array.from(wechatArticles.values()).sort((a, b) => b.created_at - a.created_at)
		}
	};
	return null;
}
/**
* 处理本地文件相关路由。
*/
async function handleLocalfilesRoute(method, path, body, host) {
	const sub = path.slice(28).replace(/^\//, "");
	if (method === "GET" && sub === "list") {
		const files = [];
		try {
			if (existsSync(LOCALFILES_DIR)) {
				const entries = readdirSync(LOCALFILES_DIR);
				for (const entry of entries) {
					const full = join(LOCALFILES_DIR, entry);
					if (!existsSync(full)) continue;
					try {
						const st = statSync(full);
						files.push({
							name: entry,
							size: st.size,
							mtime: st.mtime.toISOString(),
							type: st.isDirectory() ? "dir" : "file"
						});
					} catch {}
				}
			}
		} catch {}
		return {
			status: 200,
			data: {
				success: true,
				files
			}
		};
	}
	if (method === "POST" && sub === "upload") {
		const { filename, content } = body;
		if (!filename) return {
			status: 400,
			data: { error: "缺少 filename" }
		};
		mkdirSync(LOCALFILES_DIR, { recursive: true });
		try {
			writeFileSync(join(LOCALFILES_DIR, filename), content, "utf8");
		} catch {}
		return {
			status: 200,
			data: {
				success: true,
				filename
			}
		};
	}
	if (method === "GET" && sub.startsWith("file/")) {
		const name = sub.slice(5);
		try {
			return {
				status: 200,
				data: {
					success: true,
					name,
					content: readFileSync(join(LOCALFILES_DIR, name), "utf8")
				}
			};
		} catch {
			return {
				status: 404,
				data: { error: "文件不存在" }
			};
		}
	}
	if (method === "DELETE" && sub.startsWith("file/")) {
		const name = sub.slice(5);
		try {
			(await import("node:fs")).unlinkSync(join(LOCALFILES_DIR, name));
			return {
				status: 200,
				data: { success: true }
			};
		} catch {
			return {
				status: 404,
				data: { error: "文件不存在" }
			};
		}
	}
	return null;
}
function rehydrateWechat() {
	loadWechatConfig();
}
//#endregion
//#region server/engines/cover-engine.ts
/**
* 小说封面设计引擎（Host 端）
* 解析 TXT / DOCX 抽取书名、作者、简介，供面板生成 3:4 封面。
*
* DOCX 是 ZIP；这里用 node:zlib 手写一个最小 ZIP 读取器，避免引入依赖，
* 只取 word/document.xml 并剥离标签。
*/
/** Parse the ZIP central directory (enough to locate + inflate one entry). */
function readZipEntries(buf) {
	let eocd = -1;
	for (let i = buf.length - 22; i >= 0 && i > buf.length - 66e3; i--) if (buf.readUInt32LE(i) === 101010256) {
		eocd = i;
		break;
	}
	if (eocd < 0) return [];
	const count = buf.readUInt16LE(eocd + 10);
	let ptr = buf.readUInt32LE(eocd + 16);
	const entries = [];
	for (let i = 0; i < count; i++) {
		if (ptr + 46 > buf.length || buf.readUInt32LE(ptr) !== 33639248) break;
		const method = buf.readUInt16LE(ptr + 10);
		const compressedSize = buf.readUInt32LE(ptr + 20);
		const nameLen = buf.readUInt16LE(ptr + 28);
		const extraLen = buf.readUInt16LE(ptr + 30);
		const commentLen = buf.readUInt16LE(ptr + 32);
		const localOffset = buf.readUInt32LE(ptr + 42);
		const name = buf.slice(ptr + 46, ptr + 46 + nameLen).toString("utf8");
		entries.push({
			name,
			offset: localOffset,
			compressedSize,
			method
		});
		ptr += 46 + nameLen + extraLen + commentLen;
	}
	return entries;
}
/** Extract one entry's bytes from the local file header. */
function readZipEntry(buf, entry) {
	const off = entry.offset;
	if (off + 30 > buf.length || buf.readUInt32LE(off) !== 67324752) return null;
	const nameLen = buf.readUInt16LE(off + 26);
	const extraLen = buf.readUInt16LE(off + 28);
	const dataStart = off + 30 + nameLen + extraLen;
	const data = buf.slice(dataStart, dataStart + entry.compressedSize);
	try {
		if (entry.method === 0) return data;
		if (entry.method === 8) return inflateRawSync(data);
	} catch {
		return null;
	}
	return null;
}
/** Pull plain text out of a .docx document body. */
function extractDocxText(buf) {
	const doc = readZipEntries(buf).find((e) => e.name === "word/document.xml");
	if (!doc) return "";
	return decodeXmlEntities((readZipEntry(buf, doc)?.toString("utf8") ?? "").replace(/<w:br\s*\/>/g, "\n").replace(/<\/w:p>/g, "\n").replace(/<w:tab\s*\/>/g, " ").replace(/<[^>]+>/g, ""));
}
function decodeXmlEntities(s) {
	return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d))).replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&amp;/g, "&");
}
/** Decode a text buffer, honouring UTF-8 BOM and falling back to GBK-ish bytes. */
function decodeText(buf) {
	let b = buf;
	if (b.length >= 3 && b[0] === 239 && b[1] === 187 && b[2] === 191) b = b.slice(3);
	const utf8 = b.toString("utf8");
	const bad = (utf8.match(/\uFFFD/g) ?? []).length;
	if (bad > 0 && bad > utf8.length * .01) try {
		return new TextDecoder("gb18030").decode(b);
	} catch {
		try {
			return new TextDecoder("gbk").decode(b);
		} catch {
			return utf8;
		}
	}
	return utf8;
}
const TITLE_HINTS = [
	/^\s*《(.+?)》\s*$/,
	/^\s*书名[:：]\s*(.+)$/,
	/^\s*title[:：]\s*(.+)$/i
];
const AUTHOR_HINTS = [
	/^\s*作者[:：]\s*(.+)$/,
	/^\s*作\s*者[:：]\s*(.+)$/,
	/^\s*by[:：]?\s*(.+)$/i,
	/^\s*著[:：]\s*(.+)$/
];
/**
* Derive title / author / summary from a novel file.
* Title falls back to the filename; summary is the opening prose with
* chapter headings and metadata lines removed.
*/
function extractNovelMeta(text, filename) {
	const nonEmpty = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
	let title = "";
	let author = "";
	for (const line of nonEmpty.slice(0, 30)) {
		if (!title) for (const re of TITLE_HINTS) {
			const m = re.exec(line);
			if (m?.[1]?.trim()) {
				title = m[1].trim();
				break;
			}
		}
		if (!author) for (const re of AUTHOR_HINTS) {
			const m = re.exec(line);
			if (m?.[1]?.trim()) {
				author = m[1].trim();
				break;
			}
		}
		if (title && author) break;
	}
	if (!title) title = basename(filename, extname(filename)).replace(/[《》]/g, "").trim() || "未命名作品";
	const noise = /^(书名|作者|作\s*者|简介|内容简介|摘要|前言|序|第[一二三四五六七八九十百千\d]+[章节回卷]|chapter\s*\d+|[-=*_—]{3,})/i;
	const isJunk = (l) => noise.test(l) || /HYPERLINK|PAGEREF|\\l\s+"|toc_auto/i.test(l) || /^[\d.\s、]+$/.test(l);
	const summary = nonEmpty.filter((l) => !isJunk(l) && l.length > 12).join("").slice(0, 400).trim();
	return {
		title: title.slice(0, 60),
		author: author.slice(0, 40),
		summary,
		charCount: text.length,
		source: filename
	};
}
/** Save an uploaded novel file and return its extracted metadata. */
function analyzeNovelFile(filename, contentBase64) {
	try {
		const buf = Buffer.from(contentBase64, "base64");
		if (buf.length === 0) return {
			ok: false,
			error: "文件内容为空"
		};
		if (buf.length > 41943040) return {
			ok: false,
			error: "文件过大（上限 40MB）"
		};
		const ext = extname(filename).toLowerCase();
		let text = "";
		if (ext === ".docx") {
			text = extractDocxText(buf);
			if (!text.trim()) return {
				ok: false,
				error: "未能从 DOCX 中解析出文字（可能不是标准 .docx，试试另存为 .txt）"
			};
		} else if (ext === ".doc") return {
			ok: false,
			error: "不支持旧版 .doc，请在 Word 中另存为 .docx 或 .txt"
		};
		else {
			text = decodeText(buf);
			if (!text.trim()) return {
				ok: false,
				error: "文件内容为空或不是纯文本"
			};
		}
		const meta = extractNovelMeta(text, filename);
		const dir = join(dataRoot(), "covers");
		if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, `source${ext === ".docx" ? ".txt" : ext}`), text, "utf8");
		return {
			ok: true,
			meta
		};
	} catch (e) {
		return {
			ok: false,
			error: e instanceof Error ? e.message : String(e)
		};
	}
}
const COVER_STYLES = [
	{
		key: "guofeng",
		name: "国风水墨",
		prompt: "Chinese ink-wash painting style, elegant, rice-paper texture, negative space, subtle red seal accent"
	},
	{
		key: "dushi",
		name: "都市写实",
		prompt: "cinematic urban photography, moody lighting, shallow depth of field, modern city atmosphere"
	},
	{
		key: "xianxia",
		name: "仙侠玄幻",
		prompt: "ethereal xianxia fantasy, glowing spiritual energy, misty mountains, dramatic celestial light"
	},
	{
		key: "xuanyi",
		name: "悬疑暗调",
		prompt: "dark suspense thriller mood, high contrast, cold tones, mysterious fog, cinematic tension"
	},
	{
		key: "yanqing",
		name: "言情清新",
		prompt: "soft romantic illustration, pastel palette, warm gentle light, dreamy bokeh"
	},
	{
		key: "kehuan",
		name: "科幻未来",
		prompt: "science-fiction concept art, neon and chrome, futuristic skyline, volumetric light"
	}
];
/** Build the image prompt for a cover. */
function buildCoverPrompt(meta, styleKey, extra) {
	const style = COVER_STYLES.find((s) => s.key === styleKey) ?? COVER_STYLES[0];
	const theme = meta.summary.slice(0, 160);
	return [
		`Book cover artwork for a Chinese web novel titled "${meta.title}".`,
		theme ? `Story theme: ${theme}` : "",
		style.prompt,
		"Vertical portrait composition with clear space at the top for the title and at the bottom for the author name.",
		"No text, no letters, no watermark in the image.",
		extra ? String(extra).slice(0, 200) : ""
	].filter(Boolean).join(" ");
}
//#endregion
//#region server/engines/prompt-expert-engine.ts
/**
* 提示词专家引擎 — Host 端
* 用户用中文说想法 → 文本模型生成专业提示词（中英文对照）
*/
const EXPERT_TYPES = [
	{
		key: "t2i",
		icon: "🖼",
		name: "文生图专家",
		desc: "把想法扩写成专业绘图提示词",
		placeholder: "例如：一个穿汉服的女孩在樱花树下弹古筝",
		fields: [
			{
				key: "style",
				label: "画面风格",
				type: "select",
				default: "不限",
				options: [
					"不限",
					"写实摄影",
					"动漫插画",
					"国风水墨",
					"赛博朋克",
					"3D渲染",
					"水彩手绘",
					"电影质感"
				]
			},
			{
				key: "ratio",
				label: "画幅比例",
				type: "select",
				default: "1:1",
				options: [
					"1:1",
					"16:9",
					"9:16",
					"4:3",
					"3:4"
				]
			},
			{
				key: "shot",
				label: "景别",
				type: "select",
				default: "不限",
				options: [
					"不限",
					"特写",
					"半身",
					"全身",
					"远景",
					"鸟瞰"
				]
			}
		]
	},
	{
		key: "i2i",
		icon: "🎨",
		name: "图生图专家",
		desc: "生成精准的改图指令",
		placeholder: "例如：把这张产品图的背景换成海边黄昏，保持产品不变",
		fields: [{
			key: "strength",
			label: "改动幅度",
			type: "select",
			default: "中等",
			options: [
				"轻微",
				"中等",
				"大幅重绘"
			]
		}, {
			key: "style",
			label: "目标风格",
			type: "select",
			default: "不限",
			options: [
				"不限",
				"写实摄影",
				"动漫插画",
				"水彩手绘",
				"3D渲染",
				"电商主图"
			]
		}]
	},
	{
		key: "t2v",
		icon: "🎬",
		name: "文生视频专家",
		desc: "生成含运镜与光线的视频提示词",
		placeholder: "例如：一只猫在夕阳下的海滩散步，海浪轻轻涌来",
		fields: [
			{
				key: "camera",
				label: "镜头运动",
				type: "select",
				default: "缓慢推进",
				options: [
					"固定镜头",
					"缓慢推进",
					"缓慢拉远",
					"左摇",
					"右摇",
					"跟随"
				]
			},
			{
				key: "duration",
				label: "时长",
				type: "select",
				default: "5秒",
				options: ["5秒", "10秒"]
			},
			{
				key: "style",
				label: "画面风格",
				type: "select",
				default: "电影感",
				options: [
					"电影感",
					"写实",
					"动漫",
					"赛博朋克",
					"国风"
				]
			}
		]
	},
	{
		key: "novel",
		icon: "📖",
		name: "小说生成专家",
		desc: "生成设定、大纲与开篇正文",
		placeholder: "例如：都市悬疑，法医女主追查连环失踪案",
		fields: [
			{
				key: "genre",
				label: "题材",
				type: "select",
				default: "都市",
				options: [
					"都市",
					"悬疑",
					"玄幻",
					"言情",
					"科幻",
					"历史",
					"恐怖"
				]
			},
			{
				key: "words",
				label: "开篇字数",
				type: "select",
				default: "800字",
				options: [
					"500字",
					"800字",
					"1500字",
					"3000字"
				]
			},
			{
				key: "tone",
				label: "文风",
				type: "select",
				default: "轻松明快",
				options: [
					"轻松明快",
					"沉稳厚重",
					"紧张刺激",
					"唯美抒情"
				]
			}
		]
	},
	{
		key: "drama",
		icon: "🎭",
		name: "短剧剧本专家",
		desc: "生成带钩子的竖屏短剧剧本",
		placeholder: "例如：外卖员逆袭成集团继承人，第一集被打脸",
		fields: [{
			key: "genre",
			label: "题材",
			type: "select",
			default: "逆袭",
			options: [
				"逆袭",
				"甜宠",
				"悬疑",
				"家庭伦理",
				"职场",
				"古装"
			]
		}, {
			key: "duration",
			label: "单集时长",
			type: "select",
			default: "1-2分钟",
			options: [
				"1分钟",
				"1-2分钟",
				"3分钟"
			]
		}]
	},
	{
		key: "anchor",
		icon: "🎙",
		name: "数字人口播专家",
		desc: "生成适合 TTS 朗读的口播稿",
		placeholder: "例如：介绍一款降噪耳机，突出性价比",
		fields: [{
			key: "length",
			label: "稿件长度",
			type: "select",
			default: "约300字",
			options: [
				"约150字",
				"约300字",
				"约500字"
			]
		}, {
			key: "tone",
			label: "语气",
			type: "select",
			default: "亲切自然",
			options: [
				"亲切自然",
				"专业理性",
				"激情带货",
				"轻松幽默"
			]
		}]
	},
	{
		key: "sheet",
		icon: "🧍",
		name: "角色三视图专家",
		desc: "生成角色设定与三视图提示词",
		placeholder: "例如：28岁职场女性，干练短发，穿深色西装",
		fields: [{
			key: "style",
			label: "画风",
			type: "select",
			default: "动漫插画",
			options: [
				"动漫插画",
				"写实",
				"国风",
				"3D渲染",
				"水彩"
			]
		}, {
			key: "gender",
			label: "性别",
			type: "select",
			default: "不限",
			options: [
				"不限",
				"男性",
				"女性"
			]
		}]
	}
];
const EXPERT_OUTPUT_RULE = `
输出格式（严格遵守，不要有任何前言、解释或 markdown 代码块）：
先输出【中文提示词】，再输出【English Prompt】，两段语义一一对应。
最后另起一行输出【推荐参数】，给出推荐尺寸/时长/风格等。`;
const EXPERT_PROMPTS = {
	t2i: () => `你是一位资深 AI 绘画提示词工程师，擅长把口语化想法改写成高质量绘图提示词。
任务：把用户用中文描述的想法，扩写成可直接投喂文生图模型的专业提示词。
${EXPERT_OUTPUT_RULE}
英文提示词要求：一段式、逗号分隔，顺序为：主体→外观细节→姿态/动作→环境背景→构图景别→光线→风格→画质词。用词具体可视觉化。`,
	i2i: () => `你是一位图生图（Image-to-Image）改图提示词专家。
任务：根据用户想对参考图做的修改，写出精确的改图指令。
${EXPERT_OUTPUT_RULE}
改图指令要求：只描述"需要改变的部分"，明确写 keep everything else unchanged。不要重复描述原图已有的内容。`,
	t2v: () => `你是一位 AI 视频生成提示词专家，熟悉文生视频模型的特性。
任务：把用户想法改写为高质量视频提示词。
${EXPERT_OUTPUT_RULE}
视频提示词要求：顺序为 [主体]+[动作]+[场景]+[镜头运动]+[光线]+[风格]，英文一段式。只写一个连贯镜头能完成的动作。必须在末尾附加：no text, no subtitles, no watermarks。`,
	novel: () => `你是一位中文小说作家与选题策划人。
任务：根据用户想法产出小说方案与开篇正文。
输出格式（严格遵守）：【标题】【故事设定】世界观+核心冲突【章节大纲】3-5章【开篇正文】【English Summary】3-5句英文概要。`,
	drama: () => `你是一位短剧编剧，熟悉竖屏短剧的创作规律。
任务：根据用户想法产出短剧剧本。
输出格式：【剧名】【人物表】2-4个角色【分场剧本】每场含场次标题、画面描述、台词【English Summary】英文概要。开篇15秒必须有强钩子。`,
	anchor: () => `你是一位短视频口播文案策划。
任务：根据用户想法产出可直接配音的口播稿。
输出格式：【标题】【口播正文】分段输出，每段40-60字【English Summary】英文概要。开头3秒必须有钩子，句子短、口语化。`,
	sheet: () => `你是一位角色设定提示词专家。
任务：根据用户描述的角色，产出用于生成"三视图设定图"的专业提示词。
${EXPERT_OUTPUT_RULE}
要求：结构为人物身份/年龄→发型发色→五官特征→服装→配饰→身材比例。画面要求：正面+侧面+背面三视图，纯白背景。`
};
async function handlePromptExpertRoute(method, urlPath, body, resolveApiKey, getVendorFromModel) {
	const ep = urlPath.replace(/^\/agnes-studio\/api\/?/, "").replace(/^prompt-expert\/?/, "");
	if (method === "GET" && ep === "types") return {
		status: 200,
		data: { types: EXPERT_TYPES }
	};
	if (method === "POST" && ep === "generate") {
		const { type: expertKey, idea, params, model } = body || {};
		if (!expertKey || !idea) return {
			status: 400,
			data: { error: "缺少专家类型或想法" }
		};
		if (!EXPERT_PROMPTS[expertKey]) return {
			status: 400,
			data: { error: `未知专家类型: ${expertKey}` }
		};
		const paramLines = [];
		if (params && typeof params === "object") {
			for (const [k, v] of Object.entries(params)) if (v && v !== "不限") paramLines.push(`${k}: ${v}`);
		}
		`${idea}${paramLines.length > 0 ? paramLines.join("；") : "（用户未指定，按专业判断补充）"}`;
		const selectedModel = model || "agnes-3.0-flash";
		const vendor = getVendorFromModel(selectedModel);
		let apiKey = "";
		try {
			apiKey = await resolveApiKey(vendor);
		} catch {
			return {
				status: 401,
				data: { error: "API Key 未配置" }
			};
		}
		try {
			const prompt = await generatePromptExpert(expertKey, idea, params ?? {}, apiKey, selectedModel);
			if (!prompt) return {
				status: 502,
				data: { error: "模型没有返回内容" }
			};
			return {
				status: 200,
				data: {
					prompt,
					model: selectedModel
				}
			};
		} catch (e) {
			return {
				status: 502,
				data: { error: e instanceof Error ? e.message : String(e) }
			};
		}
	}
	return null;
}
async function callTextModelLocal(sysPrompt, userPrompt, apiKey, model, maxTokens = 2048) {
	const baseUrl = VENDOR_BASE_URLS[getVendorFromModel(model)] || VENDOR_BASE_URLS.agnes;
	const ac = new AbortController();
	const t = setTimeout(() => ac.abort(), 12e4);
	try {
		const r = await fetch(`${baseUrl}/chat/completions`, {
			method: "POST",
			signal: ac.signal,
			headers: {
				"Authorization": `Bearer ${apiKey}`,
				"Content-Type": "application/json"
			},
			body: JSON.stringify({
				model,
				messages: [{
					role: "system",
					content: sysPrompt
				}, {
					role: "user",
					content: userPrompt
				}],
				max_tokens: maxTokens,
				temperature: .7
			})
		});
		if (!r.ok) throw new Error(`API ${r.status}: ${(await r.text()).slice(0, 300)}`);
		return (await r.json()).choices?.[0]?.message?.content || "";
	} finally {
		clearTimeout(t);
	}
}
async function generatePromptExpert(expertKey, idea, params, apiKey, model) {
	const promptBuilder = EXPERT_PROMPTS[expertKey];
	if (!promptBuilder) throw new Error(`未知专家类型: ${expertKey}`);
	const paramLines = [];
	for (const [k, v] of Object.entries(params)) if (v && v !== "不限") paramLines.push(`${k}: ${v}`);
	const userPrompt = `用户的想法：${idea}\n\n用户选择的参数：${paramLines.length > 0 ? paramLines.join("；") : "（用户未指定，按专业判断补充）"}\n\n请按系统提示要求的格式输出结果。`;
	return (await callTextModelLocal(promptBuilder(), userPrompt, apiKey, model, 2048)).trim();
}
//#endregion
//#region server/engines/assets-engine.ts
/**
* 素材库引擎 —— 浏览本机下载的素材包。
*
* ═══════════════════════════════════════════════════════════════════════
* ⚠️ 版权与访问边界（这是本模块的第一设计约束，不是附注）
*
* 素材来自天猫「唐峰旗舰店」售卖的付费素材包（证据见
* m3e-canvas/docs/HANDOVER-交接.md 第 8 节：zip 内的说明 txt 与 .url 快捷方式）。
* 把原文件公开给任意访客，属于未经授权分发他人付费作品。
*
* 所以本引擎**只负责浏览能力**，访问边界交给调用方（host-entry）：
*   · 默认仅 127.0.0.1 可用；
*   · 想局域网/公网访问必须显式设 ASSETS_ALLOW_REMOTE=1 —— 那是使用者的决定。
*
* 技术上还有一招缓解（已实现）：缩略图与原件走**两个不同端点**，
* 关掉 /assets/file 就只留小图预览，访客拿不到原文件。
* ═══════════════════════════════════════════════════════════════════════
*/
const execFileAsync = promisify(execFile);
/** 列目录时跳过的名字。 */
const SKIP = /* @__PURE__ */ new Set([
	"node_modules",
	".git",
	".DS_Store",
	"Thumbs.db"
]);
/** 按扩展名归类。 */
function kindOfFile(name) {
	const e = extname(name).toLowerCase();
	if ([
		".jpg",
		".jpeg",
		".png",
		".webp",
		".gif",
		".bmp",
		".tiff"
	].includes(e)) return "image";
	if ([
		".mp4",
		".mov",
		".mkv",
		".webm",
		".avi",
		".m4v"
	].includes(e)) return "video";
	if ([
		".mp3",
		".wav",
		".m4a",
		".flac",
		".ogg",
		".aac"
	].includes(e)) return "audio";
	if ([
		".zip",
		".rar",
		".7z",
		".tar",
		".gz"
	].includes(e)) return "archive";
	if ([
		".eps",
		".xd",
		".sketch",
		".ai",
		".psd",
		".svg",
		".cdr"
	].includes(e)) return "design";
	if ([
		".ttf",
		".otf",
		".woff",
		".woff2"
	].includes(e)) return "font";
	if ([
		".txt",
		".md",
		".pdf",
		".url",
		".json",
		".doc",
		".docx",
		".xls",
		".xlsx"
	].includes(e)) return "doc";
	return "other";
}
/** 缩略图只对这几类做（其它类型没有可视内容）。 */
const THUMBNABLE = /* @__PURE__ */ new Set([
	".jpg",
	".jpeg",
	".png",
	".webp",
	".gif",
	".bmp",
	".tiff"
]);
/**
* 把 rel（格式 `<根名>/a/b`）解析成绝对路径。
* rel 为空 = 根层（列出所有素材库），返回 null。
*/
function resolveRel(host, rel) {
	const segs = String(rel || "").split("/").filter((s) => s && s !== "." && s !== "..");
	if (!segs.length) return null;
	const hit = host.roots.find((r) => r.name === segs[0]);
	if (!hit) throw new Error("没有这个素材库：" + segs[0]);
	const inner = segs.slice(1);
	const base = resolve(hit.path);
	const abs = resolve(base, ...inner);
	if (abs !== base && !abs.startsWith(base + sep)) throw new Error("路径超出素材库");
	return {
		abs,
		rootName: hit.name,
		inner: inner.join("/")
	};
}
/** 统计缓存：全量扫一次，60 秒内复用（47GB 目录树也不至于每次请求都重扫）。 */
let statsCache = null;
/** 统计：汇总所有素材根。 */
function assetsStats(host, force = false) {
	const key = host.roots.map((r) => r.path).join("|");
	if (!force && statsCache && statsCache.root === key && Date.now() - statsCache.at < 6e4) return statsCache.data;
	const merged = {
		roots: host.roots.map((r) => ({
			name: r.name,
			path: r.path,
			exists: existsSync(r.path)
		})),
		counts: {},
		bytes: {},
		total: {
			files: 0,
			bytes: 0
		}
	};
	const counts = merged.counts;
	const bytes = merged.bytes;
	const total = merged.total;
	for (const r of host.roots) {
		if (!existsSync(r.path)) continue;
		const one = scanStats(r.path);
		for (const [k, v] of Object.entries(one.counts)) counts[k] = (counts[k] || 0) + v;
		for (const [k, v] of Object.entries(one.bytes)) bytes[k] = (bytes[k] || 0) + v;
		const t = one.total;
		total.files += t.files;
		total.bytes += t.bytes;
	}
	statsCache = {
		at: Date.now(),
		root: key,
		data: merged
	};
	return merged;
}
/** 真正干活的那次扫描（只 stat，不读内容，所以再大也快）。 */
function scanStats(root) {
	const out = {
		root,
		exists: existsSync(root),
		counts: {},
		bytes: {},
		topDirs: [],
		total: {
			files: 0,
			bytes: 0
		}
	};
	if (!out.exists) return out;
	const walk = (dir, depth, acc) => {
		let items = [];
		try {
			items = readdirSync(dir);
		} catch {
			return;
		}
		for (const name of items) {
			if (SKIP.has(name)) continue;
			const p = join(dir, name);
			try {
				const st = statSync(p);
				if (st.isDirectory()) {
					if (depth < 12 && acc.files < 2e5) walk(p, depth + 1, acc);
				} else if (st.isFile()) {
					acc.files++;
					acc.bytes += st.size;
					const k = kindOfFile(name);
					out.counts[k] = (out.counts[k] || 0) + 1;
					out.bytes[k] = (out.bytes[k] || 0) + st.size;
				}
			} catch {}
		}
	};
	for (const name of (() => {
		try {
			return readdirSync(root);
		} catch {
			return [];
		}
	})()) {
		if (SKIP.has(name)) continue;
		const p = join(root, name);
		try {
			if (statSync(p).isDirectory()) {
				const acc = {
					files: 0,
					bytes: 0
				};
				walk(p, 1, acc);
				out.topDirs.push({
					name,
					files: acc.files,
					bytes: acc.bytes
				});
				out.total.files += acc.files;
				out.total.bytes += acc.bytes;
			}
		} catch {}
	}
	out.topDirs.sort((a, b) => b.bytes - a.bytes);
	return out;
}
/** 列一个目录：只列当前层（不递归），带分页、搜索与类型筛选。 */
function assetsList(host, rel, opts = {}) {
	const resolved = resolveRel(host, rel);
	if (!resolved) return {
		rel: "",
		dirs: host.roots.map((r) => ({
			name: r.name,
			rel: r.name,
			type: "dir",
			exists: existsSync(r.path)
		})),
		files: [],
		total: 0,
		offset: 0,
		limit: 0,
		hasMore: false,
		counts: {
			dirs: host.roots.length,
			files: 0
		}
	};
	const dir = resolved.abs;
	if (!existsSync(dir)) throw new Error("目录不存在：" + (rel || "/"));
	const limit = Math.max(1, Math.min(200, opts.limit || 60));
	const offset = Math.max(0, opts.offset || 0);
	const q = String(opts.q || "").trim().toLowerCase();
	const kind = String(opts.kind || "").trim();
	let names = [];
	try {
		names = readdirSync(dir);
	} catch {
		throw new Error("读不到这个目录（可能是权限问题）");
	}
	const dirs = [];
	const files = [];
	for (const name of names) {
		if (SKIP.has(name)) continue;
		const p = join(dir, name);
		let st;
		try {
			st = statSync(p);
		} catch {
			continue;
		}
		const relPath = rel ? `${rel}/${name}` : name;
		if (st.isDirectory()) dirs.push({
			name,
			rel: relPath,
			type: "dir"
		});
		else if (st.isFile()) {
			const k = kindOfFile(name);
			if (kind && k !== kind) continue;
			if (q && !name.toLowerCase().includes(q)) continue;
			files.push({
				name,
				rel: relPath,
				type: "file",
				kind: k,
				size: st.size
			});
		}
	}
	dirs.sort((a, b) => String(a.name).localeCompare(String(b.name)));
	files.sort((a, b) => {
		const an = String(a.name);
		const bn = String(b.name);
		return an.localeCompare(bn, "zh-Hans-CN", { numeric: true });
	});
	const total = files.length;
	const page = files.slice(offset, offset + limit);
	return {
		rel: rel || "",
		dirs,
		files: page,
		total,
		offset,
		limit,
		hasMore: offset + page.length < total,
		counts: {
			dirs: dirs.length,
			files: total
		}
	};
}
/** 用 ghostscript 把 EPS 渲成 PNG。装不上 gs 就返回 false（不报错，退化为无预览）。 */
async function renderEps(src, out, width) {
	try {
		const raw = out + ".raw.png";
		await execFileAsync("gs", [
			"-dSAFER",
			"-dBATCH",
			"-dNOPAUSE",
			"-dQUIET",
			"-sDEVICE=png16m",
			"-dEPSCrop",
			"-dTextAlphaBits=4",
			"-dGraphicsAlphaBits=4",
			"-r96",
			`-sOutputFile=${raw}`,
			src
		], {
			timeout: 9e4,
			maxBuffer: 8 << 20
		});
		if (!existsSync(raw)) return false;
		const r = await ffmpeg$1([
			"-i",
			raw,
			"-vf",
			`scale=${width}:-2:flags=lanczos`,
			"-q:v",
			"4",
			"-frames:v",
			"1",
			out
		], 6e4);
		rmSync(raw, { force: true });
		return r.ok && existsSync(out);
	} catch {
		return false;
	}
}
/**
* 从 zip 里取第一个可预览的文件并渲染。
* 素材库里 1210 个 zip 装的是 EPS 设计稿，不进去解一层，访客就只能看到压缩包名字。
*/
async function zipThumb(src, out, width) {
	try {
		if (statSync(src).size > 629145600) return false;
		const UENV = {
			...process.env,
			LANG: "C.UTF-8",
			LC_ALL: "C.UTF-8"
		};
		const tmpDir = join(tmpdir(), "asset-zip-" + Date.now().toString(36));
		mkdirSync(tmpDir, { recursive: true });
		try {
			try {
				await execFileAsync("unzip", [
					"-o",
					"-qq",
					src,
					"-d",
					tmpDir
				], {
					timeout: 24e4,
					maxBuffer: 64 << 20,
					env: UENV
				});
			} catch (e) {
				console.warn("[assets] unzip 返回非零（通常是文件名编码不一致，文件已解出）:", src, e instanceof Error ? e.message.slice(0, 120) : e);
			}
			const found = [];
			const walk = (d, depth) => {
				if (depth > 4 || found.length > 60) return;
				let items = [];
				try {
					items = readdirSync(d);
				} catch {
					return;
				}
				for (const n of items) {
					const p = join(d, n);
					try {
						if (statSync(p).isDirectory()) walk(p, depth + 1);
						else if (/\.(jpg|jpeg|png|webp)$/i.test(n)) found.push(p);
						else if (/\.eps$/i.test(n)) found.push(p);
					} catch {}
				}
			};
			walk(tmpDir, 0);
			const pick = found.find((x) => /\.(jpg|jpeg|png|webp)$/i.test(x)) || found.find((x) => /\.eps$/i.test(x));
			if (!pick) return false;
			if (/\.eps$/i.test(pick)) return await renderEps(pick, out, width);
			return (await ffmpeg$1([
				"-i",
				pick,
				"-vf",
				`scale=${width}:-2:flags=lanczos`,
				"-q:v",
				"4",
				"-frames:v",
				"1",
				out
			], 9e4)).ok && existsSync(out);
		} finally {
			rmSync(tmpDir, {
				recursive: true,
				force: true
			});
		}
	} catch (e) {
		console.warn("[assets] zip 预览失败:", src, e instanceof Error ? e.message.slice(0, 160) : e);
		return false;
	}
}
/** 生成（或复用）一张缩略图，返回文件绝对路径；不支持的返回 null。 */
async function assetsThumb(host, rel, width = 360) {
	const r0 = resolveRel(host, rel);
	if (!r0) throw new Error("缺少文件路径");
	const src = r0.abs;
	if (!existsSync(src) || !statSync(src).isFile()) throw new Error("文件不存在");
	const ext = extname(src).toLowerCase();
	const isZip = ext === ".zip";
	const isEps = ext === ".eps";
	if (!THUMBNABLE.has(ext) && !isZip && !isEps) return null;
	const key = Buffer.from(rel).toString("base64url").slice(0, 120) + `-w${width}.jpg`;
	const out = join(host.thumbDir, key);
	mkdirSync(host.thumbDir, { recursive: true });
	if (existsSync(out)) try {
		if (statSync(out).mtimeMs >= statSync(src).mtimeMs) return out;
	} catch {}
	let okFlag = false;
	if (isZip) okFlag = await zipThumb(src, out, width);
	else if (isEps) okFlag = await renderEps(src, out, width);
	else okFlag = (await ffmpeg$1([
		"-i",
		src,
		"-vf",
		`scale=${width}:-2:flags=lanczos`,
		"-q:v",
		"4",
		"-frames:v",
		"1",
		out
	], 6e4)).ok && existsSync(out);
	if (okFlag) return out;
	return THUMBNABLE.has(ext) ? src : null;
}
/** 处理素材库路由。 */
async function handleAssetsRoute(method, path, host) {
	const rest = path.slice(24).replace(/^\//, "");
	const sub = rest.split("?")[0];
	const url = new URL(`http://dsh.invalid/${rest}`);
	const Q = (k) => url.searchParams.get(k) || "";
	try {
		if (method !== "GET") return {
			status: 405,
			data: { error: "素材库只支持 GET（浏览）" }
		};
		if (!host.roots.some((r) => existsSync(r.path))) return {
			status: 404,
			data: {
				error: "一个素材目录都不存在",
				roots: host.roots.map((r) => r.path),
				hint: "把素材目录设到环境变量 ASSETS_DIR（多个用 : 分隔），或确认它被挂进容器"
			}
		};
		if (sub === "stats") return {
			status: 200,
			data: {
				success: true,
				mode: host.mode || "local",
				...assetsStats(host, Q("force") === "1")
			}
		};
		if (sub === "list") return {
			status: 200,
			data: {
				success: true,
				...assetsList(host, Q("dir"), {
					offset: Number(Q("offset")) || 0,
					limit: Number(Q("limit")) || 60,
					q: Q("q"),
					kind: Q("kind")
				})
			}
		};
		if (sub === "thumb") {
			const rel = Q("path");
			if (!rel) return {
				status: 400,
				data: { error: "缺少 path" }
			};
			const t = await assetsThumb(host, rel, Math.max(80, Math.min(800, Number(Q("w")) || 360)));
			if (!t) return {
				status: 415,
				data: {
					error: "这种文件没有可预览的缩略图",
					kind: kindOfFile(rel)
				}
			};
			return {
				status: 200,
				data: {
					success: true,
					file: t
				}
			};
		}
		if (sub === "file") {
			const rel = Q("path");
			if (!rel) return {
				status: 400,
				data: { error: "缺少 path" }
			};
			const rf = resolveRel(host, rel);
			if (!rf) return {
				status: 400,
				data: { error: "缺少 path" }
			};
			const f = rf.abs;
			if (!existsSync(f) || !statSync(f).isFile()) return {
				status: 404,
				data: { error: "文件不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					file: f,
					size: statSync(f).size,
					kind: kindOfFile(rel)
				}
			};
		}
		return null;
	} catch (e) {
		return {
			status: 500,
			data: { error: e instanceof Error ? e.message : String(e) }
		};
	}
}
//#endregion
//#region server/engines/slice-engine.ts
/**
* 视频剪切引擎 —— 把长视频切成片段。
*
* 常见用途：从一段素材里截出要用的几段、把长视频均分成小段、
* 或者给「视频解说」那种流程准备剪辑素材。
*
* 两种模式：
*   · cut   ：按起止时间截一段（-ss/-to）
*   · split ：按段长或段数均分（长视频一次性切成 N 段）
*
* 优先 `-c copy`（不重编码，秒级完成）；但关键帧不总在切点上，
* copy 会带进前面一点多余画面，所以提供 `precise` 选项改用重编码。
*/
const SLICE_DIR = join(dataRoot(), "slice");
const tasks = /* @__PURE__ */ new Map();
function taskDir(id) {
	const d = join(SLICE_DIR, id);
	mkdirSync(d, { recursive: true });
	return d;
}
/** 把素材落到本地：支持 http(s)、本地路径。 */
async function materialize(src, outFile) {
	const s = String(src || "").trim();
	if (!s) throw new Error("缺少视频来源");
	if (/^https?:\/\//i.test(s)) {
		const r = await fetch(s, { signal: AbortSignal.timeout(9e5) });
		if (!r.ok) throw new Error(`下载视频失败：HTTP ${r.status}`);
		const buf = Buffer.from(await r.arrayBuffer());
		if (!buf.length) throw new Error("下载到的是空文件");
		const { writeFileSync } = await import("node:fs");
		writeFileSync(outFile, buf);
		return outFile;
	}
	if (!existsSync(s)) throw new Error(`视频文件不存在：${s}`);
	return s;
}
function safeName(s) {
	return String(s || "").replace(/[\s/\\:*?"<>|]+/g, "_").slice(0, 40) || "video";
}
/**
* 截取一段。
* @param precise true 时重编码（切点精确，慢）；false 时流复制（快，切点近似关键帧）
*/
/**
* 校验切出来的片段是不是真的能用。
*
* `-c copy` 在关键帧稀疏的素材上会切出「只有几帧、甚至 262 字节」的空壳，
* 而 ffmpeg 仍然退出码 0 —— 不看产物就会把这当成成功交出去。
*/
async function verifyClip(file, expectSec) {
	try {
		if (!existsSync(file)) return false;
		if (statSync(file).size < 8192) return false;
		const info = await probeMedia(file);
		if (!info.ok) return false;
		return Number(info.duration || 0) > Math.min(.3, expectSec * .3);
	} catch {
		return false;
	}
}
async function cutOne(input, output, start, end, precise) {
	const dur = Math.max(.05, end - start);
	if (precise) {
		const r = await ffmpeg$1([
			"-ss",
			String(start),
			"-i",
			input,
			"-t",
			String(dur),
			"-c:v",
			"libx264",
			"-preset",
			"veryfast",
			"-crf",
			"20",
			"-c:a",
			"aac",
			"-b:a",
			"128k",
			"-movflags",
			"+faststart",
			output
		], 18e5);
		if (!r.ok) return {
			ok: false,
			error: r.error || r.stderr?.slice(0, 200)
		};
		if (!await verifyClip(output, dur)) return {
			ok: false,
			error: "精确切割后片段仍为空，检查起始时间是否超出视频长度"
		};
		return { ok: true };
	}
	if ((await ffmpeg$1([
		"-ss",
		String(start),
		"-i",
		input,
		"-t",
		String(dur),
		"-c",
		"copy",
		"-avoid_negative_ts",
		"make_zero",
		"-movflags",
		"+faststart",
		output
	], 18e5)).ok && await verifyClip(output, dur)) return { ok: true };
	const r2 = await ffmpeg$1([
		"-ss",
		String(start),
		"-i",
		input,
		"-t",
		String(dur),
		"-c:v",
		"libx264",
		"-preset",
		"veryfast",
		"-crf",
		"22",
		"-c:a",
		"aac",
		"-b:a",
		"128k",
		"-movflags",
		"+faststart",
		output
	], 18e5);
	if (!r2.ok) return {
		ok: false,
		error: r2.error || r2.stderr?.slice(0, 200)
	};
	if (!await verifyClip(output, dur)) return {
		ok: false,
		error: "切出来的片段是空的（这段素材可能没有关键帧，可勾选「精确切割」再试）"
	};
	return {
		ok: true,
		reencoded: true
	};
}
async function runTask(task, opts) {
	const dir = taskDir(task.id);
	try {
		task.status = "running";
		task.message = "正在准备视频…";
		const ext = extname(String(task.source)).toLowerCase() || ".mp4";
		const input = await materialize(String(task.source), join(dir, "source" + (ext.length <= 5 ? ext : ".mp4")));
		const info = await probeMedia(input);
		if (!info.ok) throw new Error("读不出视频信息：" + (info.error || "格式不支持"));
		const total = Number(info.duration || 0);
		if (!(total > 0)) throw new Error("这个视频读不到时长，无法剪切");
		task.duration = total;
		task.width = info.width;
		task.height = info.height;
		const segs = [];
		if (task.mode === "cut") {
			const s = Math.max(0, Number(opts.start) || 0);
			const e = Math.min(total, Number(opts.end) || total);
			if (e - s < .2) throw new Error(`起止时间不对：结束（${e}）必须大于开始（${s}）`);
			segs.push({
				start: s,
				end: e
			});
		} else {
			let count = Number(opts.count) || 0;
			const sec = Number(opts.segmentSec) || 0;
			if (!count && sec > 0) count = Math.max(1, Math.ceil(total / sec));
			count = Math.max(1, Math.min(60, count || 4));
			const each = total / count;
			for (let i = 0; i < count; i++) segs.push({
				start: i * each,
				end: Math.min(total, (i + 1) * each)
			});
		}
		for (let i = 0; i < segs.length; i++) {
			task.segments[i].start = segs[i].start;
			task.segments[i].end = segs[i].end;
		}
		const precise = opts.precise === true;
		for (let i = 0; i < segs.length; i++) {
			task.message = `正在剪第 ${i + 1}/${segs.length} 段…`;
			const out = join(dir, `part_${String(i + 1).padStart(2, "0")}.mp4`);
			const r = await cutOne(input, out, segs[i].start, segs[i].end, precise);
			if (!r.ok) throw new Error(`第 ${i + 1} 段剪切失败：${r.error || ""}`);
			task.segments[i].file = out;
			try {
				task.segments[i].size = statSync(out).size;
			} catch {}
		}
		task.status = "done";
		task.message = `完成：${segs.length} 段，共 ${total.toFixed(1)} 秒素材`;
	} catch (e) {
		task.status = "failed";
		task.error = e instanceof Error ? e.message : String(e);
		task.message = "剪切失败：" + task.error;
	}
}
async function handleSliceRoute(method, path, body) {
	const rest = path.slice(23).replace(/^\//, "");
	const sub = rest.split("?")[0];
	const url = new URL(`http://dsh.invalid/${rest}`);
	const Q = (k) => url.searchParams.get(k) || "";
	const B = body;
	try {
		if (method === "POST" && sub === "probe") {
			const src = String(B.video_file || "").trim();
			if (!src) return {
				status: 400,
				data: { error: "缺少 video_file（链接或服务器上的路径）" }
			};
			const dir = join(SLICE_DIR, "_probe");
			mkdirSync(dir, { recursive: true });
			const ext = extname(src).toLowerCase();
			const info = await probeMedia(await materialize(src, join(dir, safeName(basename(src)) + (ext.length <= 5 ? ext : ".mp4"))));
			if (!info.ok) return {
				status: 500,
				data: { error: "读不出视频信息：" + (info.error || "") }
			};
			return {
				status: 200,
				data: {
					success: true,
					duration: info.duration,
					width: info.width,
					height: info.height,
					hasAudio: info.hasAudio,
					videoCodec: info.videoCodec,
					fps: info.fps
				}
			};
		}
		if (method === "POST" && sub === "cut") {
			const src = String(B.video_file || "").trim();
			if (!src) return {
				status: 400,
				data: { error: "缺少 video_file" }
			};
			const id = randomUUID().slice(0, 8);
			const task = {
				id,
				status: "running",
				message: "已提交",
				source: src,
				mode: "cut",
				segments: [{
					index: 1,
					start: Number(B.start) || 0,
					end: Number(B.end) || 0
				}],
				created_at: Date.now()
			};
			tasks.set(id, task);
			runTask(task, {
				start: B.start,
				end: B.end,
				precise: B.precise
			}).catch(() => {});
			return {
				status: 200,
				data: {
					success: true,
					id
				}
			};
		}
		if (method === "POST" && sub === "split") {
			const src = String(B.video_file || "").trim();
			if (!src) return {
				status: 400,
				data: { error: "缺少 video_file" }
			};
			const id = randomUUID().slice(0, 8);
			const count = Math.max(1, Math.min(60, Number(B.count) || 4));
			const task = {
				id,
				status: "running",
				message: "已提交",
				source: src,
				mode: "split",
				segments: Array.from({ length: count }, (_, i) => ({
					index: i + 1,
					start: 0,
					end: 0
				})),
				created_at: Date.now()
			};
			tasks.set(id, task);
			runTask(task, {
				count,
				segmentSec: B.segment_sec,
				precise: B.precise
			}).catch(() => {});
			return {
				status: 200,
				data: {
					success: true,
					id
				}
			};
		}
		if (method === "GET" && sub.startsWith("status")) {
			const t = tasks.get(Q("id"));
			if (!t) return {
				status: 404,
				data: { error: "任务不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					task: {
						...t,
						segments: t.segments.map((s) => ({
							index: s.index,
							start: Number(s.start.toFixed(2)),
							end: Number(s.end.toFixed(2)),
							size: s.size,
							name: s.file ? basename(s.file) : void 0
						}))
					}
				}
			};
		}
		if (method === "GET" && sub === "list") {
			const out = [];
			try {
				for (const id of readdirSync(SLICE_DIR)) {
					if (id.startsWith("_")) continue;
					const d = join(SLICE_DIR, id);
					for (const f of readdirSync(d)) {
						if (!f.endsWith(".mp4") || f === "source.mp4") continue;
						const st = statSync(join(d, f));
						out.push({
							name: f,
							rel: `${id}/${f}`,
							size: st.size,
							mtime: st.mtimeMs
						});
					}
				}
			} catch {}
			out.sort((a, b) => Number(b.mtime) - Number(a.mtime));
			return {
				status: 200,
				data: {
					success: true,
					items: out.slice(0, 100)
				}
			};
		}
		if (method === "POST" && sub === "delete") {
			const segs = String(B.rel || "").split("/").filter((x) => x && x !== "." && x !== "..");
			if (segs.length < 2) return {
				status: 400,
				data: { error: "缺少 rel" }
			};
			const f = join(SLICE_DIR, ...segs);
			if (!existsSync(f)) return {
				status: 404,
				data: { error: "片段不存在" }
			};
			rmSync(f, { force: true });
			return {
				status: 200,
				data: { success: true }
			};
		}
		return null;
	} catch (e) {
		return {
			status: 500,
			data: { error: e instanceof Error ? e.message : String(e) }
		};
	}
}
//#endregion
//#region server/engines/library-engine.ts
/**
* 资料库 —— 把所有模块生成的东西汇总到一处预览。
*
* 各模块（生图 / 生视频 / 口播 / 短剧 / MTV / 背景视频 / 剪视频 /
* 工具箱下载与配音 / 视频解析 / 小说工具 / 封面）本来各存各的目录，
* 用户想找刚生成的东西得挨个模块翻。这里统一列出来。
*
* 安全边界：只扫白名单里的顶层目录，rel 逐段过滤 `..`，
* 不允许用这个接口读项目里的其它文件。
*/
/** 顶层目录 → 显示用的来源名。顺序即界面上的默认排序权重。 */
const SOURCES = {
	slice: "剪视频",
	bgvideo: "背景视频",
	mv: "MTV",
	dramas: "短剧",
	anchors: "口播",
	covers: "封面",
	images: "生图",
	videos: "生视频",
	audios: "音频",
	videoparse: "视频解析",
	toolbox: "工具箱",
	novel: "小说工具",
	wechat: "公众号"
};
/** 这些子目录里放的是配置/日志，不是产物，不列出来。 */
const SKIP_NAMES = /* @__PURE__ */ new Set([
	"asset-thumbs",
	"localfiles",
	"wechat-config.json"
]);
const KIND_BY_EXT = {
	".png": "image",
	".jpg": "image",
	".jpeg": "image",
	".webp": "image",
	".gif": "image",
	".mp4": "video",
	".mov": "video",
	".webm": "video",
	".mkv": "video",
	".wav": "audio",
	".mp3": "audio",
	".m4a": "audio",
	".flac": "audio",
	".md": "text",
	".txt": "text",
	".json": "text",
	".srt": "text",
	".ass": "text"
};
function kindOf(name) {
	return KIND_BY_EXT[extname(name).toLowerCase()] || "other";
}
/** rel → 绝对路径（限死在 data 根与白名单顶层目录内）。 */
function libraryPath(rel) {
	const segs = String(rel || "").split("/").filter((s) => s && s !== "." && s !== "..");
	if (!segs.length) throw new Error("缺少路径");
	const top = segs[0];
	if (!SOURCES[top] && top !== "toolbox") throw new Error("不允许访问这个目录：" + top);
	const root = resolve(dataRoot());
	const abs = resolve(root, ...segs);
	if (abs !== root && !abs.startsWith(root + sep)) throw new Error("路径超出资料库");
	return abs;
}
/**
* 列出全部产物。
*
* 只 stat 不读内容；按修改时间倒序，最新的排前面。
*/
function listLibrary(opts = {}) {
	const root = dataRoot();
	const out = [];
	const wantKind = String(opts.kind || "").trim();
	const q = String(opts.q || "").trim().toLowerCase();
	const limit = Math.max(1, Math.min(500, opts.limit || 200));
	for (const top of Object.keys(SOURCES)) {
		const dir = join(root, top);
		if (!existsSync(dir)) continue;
		const walk = (d, depth) => {
			if (depth > 4 || out.length > 4e3) return;
			let items = [];
			try {
				items = readdirSync(d);
			} catch {
				return;
			}
			for (const name of items) {
				if (SKIP_NAMES.has(name)) continue;
				const p = join(d, name);
				let st;
				try {
					st = statSync(p);
				} catch {
					continue;
				}
				if (st.isDirectory()) {
					walk(p, depth + 1);
					continue;
				}
				const kind = kindOf(name);
				if (kind === "other") continue;
				if (wantKind && kind !== wantKind) continue;
				if (q && !name.toLowerCase().includes(q)) continue;
				const rel = p.slice(root.length + 1).split(sep).join("/");
				out.push({
					rel,
					name,
					kind,
					source: SOURCES[top] || top,
					size: st.size,
					mtime: st.mtimeMs
				});
			}
		};
		walk(dir, 0);
	}
	out.sort((a, b) => b.mtime - a.mtime);
	return out.slice(0, limit);
}
/** 缩略图缓存目录。 */
function thumbDir() {
	const d = join(dataRoot(), "library-thumbs");
	mkdirSync(d, { recursive: true });
	return d;
}
/**
* 生成（或复用）缩略图。
* 图片直接缩放；视频抽第 1 秒的一帧当封面；音频返回 null（前端用图标）。
*/
async function libraryThumb(rel, width = 320) {
	const src = libraryPath(rel);
	if (!existsSync(src) || !statSync(src).isFile()) throw new Error("文件不存在");
	const kind = kindOf(rel);
	if (kind === "image") {
		const key = Buffer.from(rel).toString("base64url").slice(0, 120) + `-w${width}.jpg`;
		const out = join(thumbDir(), key);
		if (existsSync(out)) try {
			if (statSync(out).mtimeMs >= statSync(src).mtimeMs) return out;
		} catch {}
		return (await ffmpeg$1([
			"-y",
			"-i",
			src,
			"-vf",
			`scale=${width}:-2:flags=lanczos`,
			"-q:v",
			"4",
			"-frames:v",
			"1",
			out
		], 6e4)).ok && existsSync(out) ? out : src;
	}
	if (kind === "video") {
		const key = "v" + Buffer.from(rel).toString("base64url").slice(0, 120) + `-w${width}.jpg`;
		const out = join(thumbDir(), key);
		if (existsSync(out)) try {
			if (statSync(out).mtimeMs >= statSync(src).mtimeMs) return out;
		} catch {}
		for (const at of ["1", "0"]) if ((await ffmpeg$1([
			"-y",
			"-ss",
			at,
			"-i",
			src,
			"-frames:v",
			"1",
			"-vf",
			`scale=${width}:-2`,
			"-q:v",
			"4",
			out
		], 9e4)).ok && existsSync(out)) return out;
		return null;
	}
	return null;
}
/**
* 把一次生成结果归档进资料库。
*
* 生图 / 生视频原来只在浏览器里显示，URL 关掉页面就没了。这里把结果
* 下载到 data/images、data/videos，之后就能在资料库里翻到。
*/
async function saveToLibrary(src, kind, name) {
	const sub = {
		image: "images",
		video: "videos",
		audio: "audios"
	}[kind] || "images";
	const dir = join(dataRoot(), sub);
	mkdirSync(dir, { recursive: true });
	const v = String(src || "").trim();
	if (!v) throw new Error("缺少内容");
	const ext = kind === "video" ? ".mp4" : kind === "audio" ? ".mp3" : ".png";
	const safe = String(name || `gen-${Date.now()}`).replace(/[\s/\\:*?"<>|]+/g, "_").slice(0, 40) || `gen-${Date.now()}`;
	const out = join(dir, safe.endsWith(ext) ? safe : safe + ext);
	if (v.startsWith("data:")) {
		const b64 = v.slice(v.indexOf(",") + 1);
		if (!b64) throw new Error("内容为空");
		const { writeFileSync } = await import("node:fs");
		writeFileSync(out, Buffer.from(b64, "base64"));
	} else if (/^https?:\/\//i.test(v)) {
		const r = await fetch(v, { signal: AbortSignal.timeout(6e5) });
		if (!r.ok) throw new Error(`下载失败：HTTP ${r.status}`);
		const buf = Buffer.from(await r.arrayBuffer());
		if (!buf.length) throw new Error("下载到的是空文件");
		const { writeFileSync } = await import("node:fs");
		writeFileSync(out, buf);
	} else throw new Error("只支持 http(s) 链接或 data URI");
	const st = statSync(out);
	return {
		rel: `${sub}/${basename(out)}`,
		size: st.size
	};
}
/** 删掉一个产物。 */
function deleteLibraryItem(rel) {
	const p = libraryPath(rel);
	if (!existsSync(p)) throw new Error("文件不存在");
	rmSync(p, { force: true });
}
/** 统计各类数量，给界面显示概览。 */
function libraryStats() {
	const items = listLibrary({ limit: 500 });
	const counts = {
		image: 0,
		video: 0,
		audio: 0,
		text: 0,
		total: items.length
	};
	for (const it of items) counts[it.kind] = (counts[it.kind] || 0) + 1;
	return counts;
}
async function handleLibraryRoute(method, path) {
	const rest = path.slice(25).replace(/^\//, "");
	const sub = rest.split("?")[0];
	const url = new URL(`http://dsh.invalid/${rest}`);
	const Q = (k) => url.searchParams.get(k) || "";
	try {
		if (method === "GET" && sub === "list") return {
			status: 200,
			data: {
				success: true,
				items: listLibrary({
					kind: Q("kind"),
					q: Q("q"),
					limit: Number(Q("limit")) || 200
				}),
				counts: libraryStats()
			}
		};
		if (method === "GET" && sub === "thumb") {
			const rel = Q("path");
			if (!rel) return {
				status: 400,
				data: { error: "缺少 path" }
			};
			const t = await libraryThumb(rel, Math.max(80, Math.min(800, Number(Q("w")) || 320)));
			if (!t) return {
				status: 200,
				data: {
					success: true,
					file: null,
					note: "这种文件没有缩略图"
				}
			};
			return {
				status: 200,
				data: {
					success: true,
					file: t
				}
			};
		}
		if (method === "GET" && sub === "file") {
			const rel = Q("path");
			if (!rel) return {
				status: 400,
				data: { error: "缺少 path" }
			};
			const f = libraryPath(rel);
			if (!existsSync(f) || !statSync(f).isFile()) return {
				status: 404,
				data: { error: "文件不存在" }
			};
			return {
				status: 200,
				data: {
					success: true,
					file: f,
					size: statSync(f).size,
					kind: kindOf(rel),
					name: basename(f)
				}
			};
		}
		return null;
	} catch (e) {
		return {
			status: 500,
			data: { error: e instanceof Error ? e.message : String(e) }
		};
	}
}
//#endregion
//#region server/engines/host-entry.ts
/**
* 网页版改造 —— 与原 DSH 插件版的**唯一差别**。
*
* 原版由 DSH 注入 ctx，密钥从 DSH 凭据 / 环境变量读；网页版没有 DSH，
* 改成「按请求」的凭据解析：当前请求携带的 Key 表优先，找不到再回落服务端 .env。
*
* handler 内部照旧写 `await ctx.credentials.resolve('agnes-api-key')`，
* 因此下面 1000 行路由分发逻辑**一行都不用改**。
*/
const requestStore = new AsyncLocalStorage();
/** Stable cordis plugin name. */
const name = "agnes-studio";
/** Required services. */
const inject = [
	"webServer",
	"systemPrompt",
	"credentials"
];
/** Platform registration URL (Agnes) —— 提示词与客户端常量都以它为准。 */
const AGNES_PLATFORM_URL = "https://platform.agnes-ai.cn";
/** Model-facing announcement. */
const AGNES_STUDIO_GUIDANCE = `本机已安装 dsh-agnes-studio 插件（泡泡猫的影视工具）：侧边栏「🎬 泡泡猫的影视工具」入口打开影视工具面板（内部即 Agnes 创意工作站）。能力：文生图、图生图、多图合成、文生视频、图生视频、剧本导入（.txt/.md/.json）、故事板编排。多厂商支持：面板现已支持 Agnes / DeepSeek / Qwen / 豆包(Doubao) / MiniMax / Ollama 六大厂商的文本、图像和视频模型，代理端点自动按模型名路由到对应厂商 API。限制：面板为全局浮层，不影响对话框；API Key 由宿主进程读取，浏览器不接触。首次使用需要对应厂商的 API Key：Agnes 在 ${AGNES_PLATFORM_URL} 注册；其他厂商各自的 Key 写入 .env（如 DEEPSEEK_API_KEY=sk-...）或 DSH 凭据（如 deepseek-api-key）。Ollama 无需 Key，需本地运行 11434 端口。本插件同时附带 Oh Story 的创作技能与工具（原 @oh-story/dsh 不再是独立插件行），共 37 个技能——短剧 11 个（short-drama 及其 develop/write/assets/image-prompts/storyboard/video-prompts/produce/edit/review/novel-analyze）、网文 13 个（story 及其 long/short 拆文与写作、封面、去 AI 味、导入、审查、扫榜）、视频解说 6 个（video-understanding/script/cut/voiceover/assemble/recap）、小说改游戏 7 个（novel-to-game 及其 analyze/concept/world-design/art-direction/build/qa），以及 oh_story_role、oh_story_production、oh_story_bundled_reference 三个工具。注意：Oh Story 的图形工作台页签已从面板撤下（功能不完善），上述技能仍可正常使用；短剧项目的创作真相是项目目录里 剧集/EPxxx 的五份 Markdown，直接编辑文件即可。用户提到「泡泡猫的影视工具 / Agnes 创意站 / 创意工作站 / 生图 / 生视频 / agnes studio / 短剧插件 / short 插件 / oh-story / 短剧 / 漫剧 / 视频解说 / 小说改游戏」时即指本插件，可引导其从侧边栏入口打开；短剧项目的创作真相仍是项目目录里 剧集/EPxxx 的五份 creator-first Markdown（剧本/视觉设定/分镜/图片提示词/视频提示词），由上述技能维护。`;
const SECTION_ORDER = 310;
/** Get vendor base URL, with optional custom override. */
function getVendorBaseUrl(vendor, customUrl) {
	if (customUrl) return customUrl;
	return VENDOR_BASE_URLS[vendor] || VENDOR_BASE_URLS.agnes;
}
/**
* Join a vendor base URL with a client endpoint without duplicating or losing
* the API version segment.
*
* The base URLs above already carry a version (`.../v1`, `.../api/v3`), while
* clients also send fully-qualified endpoints (`/v1/images/generations`,
* `/v2/video_generation`). Naive concatenation produced `.../v1/v1/...`, which
* Agnes answered with 404 — every image/video call from the panel failed.
*
* Rules:
*   base .../v1 + /v1/images/...   → .../v1/images/...   (version deduped)
*   base .../v1 + /images/...      → .../v1/images/...
*   base .../v1 + /v2/video_gen    → .../v2/video_gen    (endpoint version wins)
*   base .../v1 + /agnesapi?...    → .../v1/agnesapi?...
*/
function buildUpstreamUrl(baseUrl, endpoint) {
	const base = String(baseUrl || "").replace(/\/+$/, "");
	const ep = "/" + String(endpoint || "").replace(/^\/+/, "");
	const baseVersion = base.match(/\/(v\d+[a-z0-9]*)$/i);
	const endpointVersion = ep.match(/^\/(v\d+[a-z0-9]*)(\/|$)/i);
	if (baseVersion && endpointVersion) return base.slice(0, base.length - baseVersion[0].length) + ep;
	return base + ep;
}
/**
* Resolve the API key for a specific vendor.
* Priority: vendor-specific credential → vendor-specific env → Agnes fallback → error.
*/
async function resolveApiKeyForVendor(ctx, vendor) {
	if (vendor === "ollama") return "ollama";
	const credentialKey = `${vendor}-api-key`;
	try {
		const resolved = await ctx.credentials.resolve(credentialKey);
		if (resolved && typeof resolved === "string" && resolved.length > 0) return resolved;
	} catch {}
	const envKey = `${vendor.toUpperCase()}_API_KEY`;
	if (process.env[envKey]) return process.env[envKey];
	throw new Error(`${vendor} API Key 未配置：请在本机 .env 写入 ${envKey}=... 或在 DSH 凭据(credentials)中新增 ${credentialKey}。` + (vendor === "agnes" ? ` Agnes Key 也可在 ${AGNES_PLATFORM_URL} 注册获取。` : ""));
}
/**
* Get key configuration status for all vendors (never exposes actual keys).
*/
async function getKeyStatus(ctx) {
	const vendors = [
		"agnes",
		"deepseek",
		"qwen",
		"doubao",
		"minimax",
		"ollama"
	];
	const status = {};
	for (const vendor of vendors) {
		if (vendor === "ollama") {
			status[vendor] = {
				configured: true,
				source: "built-in",
				envKey: "",
				credentialKey: ""
			};
			continue;
		}
		try {
			const resolved = await ctx.credentials.resolve(`${vendor}-api-key`);
			if (resolved && typeof resolved === "string" && resolved.length > 0) {
				status[vendor] = {
					configured: true,
					source: "credentials",
					envKey: `${vendor.toUpperCase()}_API_KEY`,
					credentialKey: `${vendor}-api-key`
				};
				continue;
			}
		} catch {}
		if (process.env[`${vendor.toUpperCase()}_API_KEY`]) {
			status[vendor] = {
				configured: true,
				source: "env",
				envKey: `${vendor.toUpperCase()}_API_KEY`,
				credentialKey: `${vendor}-api-key`
			};
			continue;
		}
		status[vendor] = {
			configured: false,
			source: null,
			envKey: `${vendor.toUpperCase()}_API_KEY`,
			credentialKey: `${vendor}-api-key`
		};
	}
	return status;
}
const TEXT_MODEL_OPTIONS = {
	"agnes-3.0-flash": "Agnes 3.0 Flash (推荐)",
	"agnes-2.5-flash": "Agnes 2.5 Flash",
	"MiniMax-M3": "MiniMax M3",
	"deepseek-v4-flash": "DeepSeek V4 Flash",
	"deepseek-chat": "DeepSeek Chat",
	"deepseek-reasoner": "DeepSeek Reasoner",
	"qwen-turbo": "Qwen Turbo",
	"qwen-plus": "Qwen Plus"
};
const IMAGE_MODEL_OPTIONS = {
	"agnes-image-2.5-flash": "Agnes Image 2.5 Flash (推荐)",
	"agnes-image-2.1-flash": "Agnes Image 2.1 Flash",
	"agnes-image-2.0-flash": "Agnes Image 2.0 Flash",
	"doubao-seedream-3-0": "豆包 Seedream 3.0",
	"minimax-image-01": "MiniMax Image 01",
	"qwen-image-plus": "Qwen Image Plus"
};
const VIDEO_MODEL_OPTIONS = {
	"agnes-video-2.5-flash": "Agnes Video 2.5 Flash (推荐)",
	"agnes-video-2.5": "Agnes Video 2.5",
	"MiniMax-H3": "MiniMax H3",
	"agnes-video-v2.0": "Agnes Video 2.0",
	"minimax-video-01": "MiniMax Video 01",
	"doubao-seaweed-t2v": "豆包 Seaweed T2V"
};
/** Supported image sizes per model prefix. */
const IMAGE_MODEL_SIZE_SUPPORTED = {
	"agnes-image": [
		"1024x1024",
		"1024x768",
		"768x1024",
		"1280x720",
		"720x1280"
	],
	"doubao-seedream": [
		"1024x1024",
		"864x1152",
		"1152x864",
		"1280x720",
		"720x1280"
	],
	"minimax-image": [
		"1024x1024",
		"1024x768",
		"768x1024",
		"1280x720",
		"720x1280"
	],
	"qwen-image": [
		"1024x1024",
		"1024x768",
		"768x1024",
		"1280x720",
		"720x1280"
	]
};
const DEFAULT_IMAGE_SIZES = [
	"1024x1024",
	"1024x768",
	"768x1024",
	"1280x720",
	"720x1280"
];
function getImageSizeOptions(model) {
	if (!model) return DEFAULT_IMAGE_SIZES;
	const m = model.toLowerCase();
	for (const [prefix, sizes] of Object.entries(IMAGE_MODEL_SIZE_SUPPORTED)) if (m.startsWith(prefix)) return [...sizes, ...DEFAULT_IMAGE_SIZES.filter((s) => !sizes.includes(s))];
	return DEFAULT_IMAGE_SIZES;
}
/** Read the full request body as a string. */
function readBody(req) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		req.on("data", (chunk) => chunks.push(chunk));
		req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
		req.on("error", reject);
	});
}
/**
* Generic fetch with timeout and bounded retries.
*
* Agnes occasionally answers 5xx with "请求上游失败，请稍后重试" — a transient
* upstream hiccup that succeeds on retry. Only clearly transient failures are
* retried, and only when the caller says the call is safe to repeat:
*   - network/abort errors (the request never produced a result)
*   - 5xx / 429 for idempotent endpoints (e.g. image generation)
* Video submission is deliberately NOT retried by default: a duplicate submit
* would create a second task and burn quota.
*/
async function vendorFetch(url, opts = {}) {
	const { timeoutMs = 12e4, retries = 0, ...fetchOpts } = opts;
	const maxAttempts = Math.max(1, retries + 1);
	let lastError = /* @__PURE__ */ new Error("请求失败");
	for (let attempt = 0; attempt < maxAttempts; attempt++) {
		const controller = new AbortController();
		const timer = setTimeout(() => controller.abort(), timeoutMs);
		try {
			const resp = await fetch(url, {
				...fetchOpts,
				signal: controller.signal
			});
			if (resp.ok) return await resp.json();
			const text = await resp.text().catch(() => "");
			const err = /* @__PURE__ */ new Error(`API ${resp.status}: ${text.slice(0, 500)}`);
			const transient = resp.status >= 500 || resp.status === 429;
			lastError = err;
			if (!transient || attempt === maxAttempts - 1) throw err;
		} catch (e) {
			const err = e instanceof Error ? e : new Error(String(e));
			lastError = err;
			if (attempt === maxAttempts - 1) throw err;
		} finally {
			clearTimeout(timer);
		}
		await new Promise((r) => setTimeout(r, 1200 * Math.pow(2, attempt)));
	}
	throw lastError;
}
function jsonResponse(res, status, data) {
	res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
	res.end(JSON.stringify(data));
}
function textResponse(res, status, text) {
	res.writeHead(status, { "content-type": "text/plain; charset=utf-8" });
	res.end(text);
}
/**
* Stream a local media file with HTTP Range support.
* Ranges matter: without them the browser cannot seek in the generated video.
*/
function serveMediaFile(req, res, file) {
	let stat;
	try {
		stat = statSync(file);
	} catch {
		textResponse(res, 404, "media not found");
		return;
	}
	if (!stat.isFile()) {
		textResponse(res, 404, "media not found");
		return;
	}
	const ext = file.slice(file.lastIndexOf(".")).toLowerCase();
	const type = ext === ".mp4" ? "video/mp4" : ext === ".webm" ? "video/webm" : ext === ".wav" ? "audio/wav" : ext === ".mp3" ? "audio/mpeg" : ext === ".png" ? "image/png" : ext === ".jpg" || ext === ".jpeg" ? "image/jpeg" : "application/octet-stream";
	const range = req.headers?.range;
	if (typeof range === "string") {
		const m = /bytes=(\d*)-(\d*)/.exec(range);
		if (m) {
			const start = m[1] === "" ? Math.max(0, stat.size - Number(m[2] || 0)) : Number(m[1]);
			const end = m[2] === "" || m[1] === "" ? stat.size - 1 : Math.min(Number(m[2]), stat.size - 1);
			if (Number.isFinite(start) && start <= end && start < stat.size) {
				res.writeHead(206, {
					"content-type": type,
					"content-length": String(end - start + 1),
					"content-range": `bytes ${start}-${end}/${stat.size}`,
					"accept-ranges": "bytes",
					"cache-control": "no-cache"
				});
				createReadStream(file, {
					start,
					end
				}).pipe(res);
				return;
			}
		}
	}
	res.writeHead(200, {
		"content-type": type,
		"content-length": String(stat.size),
		"accept-ranges": "bytes",
		"cache-control": "no-cache"
	});
	createReadStream(file).pipe(res);
}
/**
* Mount the multi-vendor API proxy routes and agent announcement.
*/
function apply(ctx) {
	rehydrateDramas();
	rehydrateAnchors();
	rehydrateBgVideos();
	rehydrateMvTasks();
	rehydrateNovelSplit();
	rehydrateToolbox();
	rehydrateVideoparse();
	rehydrateWechat();
	ctx.effect(() => {
		const handler = async (req, res) => {
			const method = req.method ?? "GET";
			const reqUrl = new URL(req.url ?? "/", "http://dsh.invalid");
			const path = reqUrl.pathname;
			const pathWithQuery = reqUrl.pathname + reqUrl.search;
			res.setHeader("Access-Control-Allow-Origin", "*");
			res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
			res.setHeader("Access-Control-Allow-Headers", "Content-Type");
			if (method === "OPTIONS") {
				res.writeHead(204);
				res.end();
				return;
			}
			if (path === "/agnes-studio/api/status") {
				if (method !== "GET" && method !== "POST") return textResponse(res, 405, "method not allowed");
				const vendors = await getKeyStatus(ctx);
				const agnesStatus = vendors.agnes ?? {
					configured: false,
					source: null
				};
				jsonResponse(res, 200, {
					configured: agnesStatus.configured,
					source: agnesStatus.source,
					vendors,
					platformUrl: AGNES_PLATFORM_URL
				});
				return;
			}
			if (path === "/agnes-studio/api/models") {
				if (method !== "GET" && method !== "POST") return textResponse(res, 405, "method not allowed");
				const query = new URL(req.url || "/", "http://x").searchParams;
				const vendor = String(query.get("vendor") || "").trim();
				if (vendor) {
					try {
						const keys = parseKeyHeaders(req.headers);
						const base = (VENDOR_BASE_URLS[vendor] || "").replace(/\/+$/, "");
						if (!base) {
							jsonResponse(res, 400, { error: "不认识的厂商：" + vendor });
							return;
						}
						const key = keys[vendor];
						if (!key && vendor !== "ollama") {
							jsonResponse(res, 200, {
								success: true,
								vendor,
								models: [],
								source: "none",
								error: "这一家还没填 Key"
							});
							return;
						}
						const auth = vendor === "ollama" ? {} : { Authorization: `Bearer ${key}` };
						const r = await fetch(`${base}/models`, {
							headers: {
								...auth,
								accept: "application/json"
							},
							signal: AbortSignal.timeout(15e3)
						});
						if (!r.ok) {
							const t = await r.text().catch(() => "");
							jsonResponse(res, 200, {
								success: true,
								vendor,
								models: [],
								source: "error",
								error: `模型列表 HTTP ${r.status}：${t.slice(0, 160)}`
							});
							return;
						}
						const j = await r.json();
						const a = (j.data || []).map((x) => String(x.id || "")).filter(Boolean);
						const b = (j.models || []).map((x) => String(x.name || "")).filter(Boolean);
						jsonResponse(res, 200, {
							success: true,
							vendor,
							models: (a.length ? a : b).sort(),
							source: "api"
						});
					} catch (e) {
						jsonResponse(res, 200, {
							success: true,
							vendor,
							models: [],
							source: "error",
							error: e instanceof Error ? e.message : String(e)
						});
					}
					return;
				}
				jsonResponse(res, 200, {
					textModels: TEXT_MODEL_OPTIONS,
					imageModels: IMAGE_MODEL_OPTIONS,
					videoModels: VIDEO_MODEL_OPTIONS,
					imageSizes: DEFAULT_IMAGE_SIZES,
					note: "这是内置目录；带 ?vendor=xxx 可以拉到当前 Key 真实可用的模型"
				});
				return;
			}
			if (path === "/agnes-studio/api/config") {
				if (method !== "POST") return textResponse(res, 405, "method not allowed");
				try {
					const body = await readBody(req);
					jsonResponse(res, 200, {
						ok: true,
						config: JSON.parse(body)
					});
				} catch (error) {
					jsonResponse(res, 400, { error: error instanceof Error ? error.message : String(error) });
				}
				return;
			}
			if (path === "/agnes-studio/api/image-sizes") {
				jsonResponse(res, 200, { sizes: getImageSizeOptions(new URL(req.url ?? "/", "http://dsh.invalid").searchParams.get("model") ?? "") });
				return;
			}
			if (path === "/agnes-studio/api/keys/balance") {
				try {
					const vendor = String(new URL(req.url || "/", "http://x").searchParams.get("vendor") || "");
					const key = parseKeyHeaders(req.headers)[vendor];
					if (!key) {
						jsonResponse(res, 200, {
							success: true,
							vendor,
							supported: false,
							note: "没填这一家的 Key"
						});
						return;
					}
					if (vendor === "deepseek") {
						const r = await fetch("https://api.deepseek.com/user/balance", {
							headers: {
								Authorization: `Bearer ${key}`,
								accept: "application/json"
							},
							signal: AbortSignal.timeout(15e3)
						});
						if (!r.ok) {
							const t = await r.text().catch(() => "");
							jsonResponse(res, 200, {
								success: true,
								vendor,
								supported: true,
								ok: false,
								note: `查询失败 HTTP ${r.status}：${t.slice(0, 120)}`
							});
							return;
						}
						const j = await r.json();
						const infos = j.balance_infos || [];
						jsonResponse(res, 200, {
							success: true,
							vendor,
							supported: true,
							ok: true,
							available: j.is_available === true,
							balances: infos.map((b) => ({
								currency: b.currency || "CNY",
								total: b.total_balance,
								granted: b.granted_balance,
								toppedUp: b.topped_up_balance
							}))
						});
						return;
					}
					jsonResponse(res, 200, {
						success: true,
						vendor,
						supported: false,
						note: "这一家没有公开的余额查询接口，需要去它的控制台看用量与余额"
					});
				} catch (e) {
					jsonResponse(res, 200, {
						success: true,
						supported: false,
						error: e instanceof Error ? e.message : String(e)
					});
				}
				return;
			}
			if (path === "/agnes-studio/api/keys/test") {
				if (method !== "POST") return textResponse(res, 405, "method not allowed");
				try {
					const keys = parseKeyHeaders(req.headers);
					const nameOf = {
						agnes: "agnes",
						deepseek: "DeepSeek",
						qwen: "通义千问",
						doubao: "豆包",
						minimax: "MiniMax",
						mimo: "MiMo（配音）",
						zhipu: "智谱 GLM",
						ollama: "Ollama（本地）"
					};
					const defaultModel = {
						agnes: "agnes-3.0-flash",
						deepseek: "deepseek-chat",
						qwen: "qwen-plus",
						doubao: "doubao-pro-32k",
						minimax: "MiniMax-Text-01",
						mimo: "mimo-v2.5-tts",
						zhipu: "glm-4-flash",
						ollama: "llama3"
					};
					/** 按模型名判定能力，用来告诉使用者「这一家的 Key 能干什么」。 */
					const abilityOf = (id) => {
						const m = String(id).toLowerCase();
						if (/image|flux|sdxl|dall|midjourney|recraft|imagen|kolors|seedream|cogview|wanx.*t2i|t2i/.test(m)) return "image";
						if (/video|kling|veo|seedance|hailuo|runway|wan|sora|pika|cogvideo|t2v/.test(m)) return "video";
						if (/tts|speech|audio|music|suno|voice|cosyvoice|t2a/.test(m)) return "audio";
						return "text";
					};
					const results = [];
					for (const vendor of Object.keys(VENDOR_BASE_URLS)) {
						const key = keys[vendor];
						if (!key && vendor !== "ollama") {
							results.push({
								vendor,
								name: nameOf[vendor] || vendor,
								ok: false,
								skipped: true,
								error: "没填这一家的 Key"
							});
							continue;
						}
						const base = VENDOR_BASE_URLS[vendor].replace(/\/+$/, "");
						const auth = vendor === "ollama" ? {} : { Authorization: `Bearer ${key}` };
						const t0 = Date.now();
						let models = [];
						let err = "";
						try {
							const r = await fetch(`${base}/models`, {
								headers: {
									...auth,
									accept: "application/json"
								},
								signal: AbortSignal.timeout(15e3)
							});
							if (r.ok) {
								const j = await r.json();
								const a = (j.data || []).map((x) => x.id).filter(Boolean);
								const b = (j.models || []).map((x) => x.name).filter(Boolean);
								models = a.length ? a : b;
							} else err = `模型列表 HTTP ${r.status}`;
						} catch (e) {
							err = "模型列表请求失败：" + (e instanceof Error ? e.message : String(e));
						}
						if (!models.length) try {
							const r2 = await fetch(`${base}/chat/completions`, {
								method: "POST",
								headers: {
									...auth,
									"Content-Type": "application/json"
								},
								body: JSON.stringify({
									model: defaultModel[vendor] || "agnes-3.0-flash",
									messages: [{
										role: "user",
										content: "hi"
									}],
									max_tokens: 1
								}),
								signal: AbortSignal.timeout(25e3)
							});
							if (r2.ok) {
								err = "";
								models = [defaultModel[vendor] || "(默认模型)"];
							} else {
								const t = await r2.text().catch(() => "");
								err = `HTTP ${r2.status}：${t.slice(0, 140)}`;
							}
						} catch (e) {
							err = e instanceof Error ? e.message : String(e);
						}
						const abilities = {
							text: 0,
							image: 0,
							video: 0,
							audio: 0
						};
						for (const m of models) {
							const k = abilityOf(m);
							abilities[k] = (abilities[k] || 0) + 1;
						}
						if (!abilities.text && models.length && Object.values(abilities).every((v) => !v)) abilities.text = 1;
						results.push({
							vendor,
							name: nameOf[vendor] || vendor,
							ok: !err,
							models: models.slice(0, 200),
							modelCount: models.length,
							abilities,
							/** 覆盖了几项（满分 4）：text / image / video / audio */
							coverage: Object.values(abilities).filter((n) => n > 0).length,
							error: err || void 0,
							ms: Date.now() - t0
						});
					}
					jsonResponse(res, 200, {
						ok: true,
						results
					});
				} catch (e) {
					jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				}
				return;
			}
			if (path === "/agnes-studio/api/proxy") {
				if (method !== "POST") return textResponse(res, 405, "method not allowed");
				try {
					const body = await readBody(req);
					const parsed = JSON.parse(body);
					const { endpoint, params, timeoutMs, baseUrl: customUrl } = parsed;
					if (!endpoint) return textResponse(res, 400, "missing endpoint");
					const vendor = parsed.vendor || getVendorFromModel(parsed.model || "");
					const apiKey = await resolveApiKeyForVendor(ctx, vendor);
					const url = buildUpstreamUrl(getVendorBaseUrl(vendor, customUrl), endpoint);
					const upstreamMethod = parsed.method === "GET" ? "GET" : "POST";
					const isImageGen = /\/images\/generations/.test(endpoint);
					const retries = /\/videos\/?$/.test(endpoint) && upstreamMethod === "POST" ? 0 : isImageGen ? 3 : upstreamMethod === "GET" ? 2 : 0;
					jsonResponse(res, 200, await vendorFetch(url, {
						method: upstreamMethod,
						headers: {
							Authorization: `Bearer ${apiKey}`,
							"Content-Type": "application/json"
						},
						body: upstreamMethod === "GET" ? void 0 : JSON.stringify(params || {}),
						timeoutMs: timeoutMs || 12e4,
						retries
					}));
				} catch (error) {
					jsonResponse(res, 502, { error: error instanceof Error ? error.message : String(error) });
				}
				return;
			}
			if (path.startsWith("/agnes-studio/api/drama")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleDramaRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					},
					resolveCredential: async (name, envName) => {
						try {
							const v = await ctx.credentials.resolve(name);
							if (v && typeof v === "string" && v.length > 0) return v;
						} catch {}
						if (process.env[envName]) return process.env[envName];
						throw new Error(`未配置 ${envName}（凭据 ${name}）。`);
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/anchor")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleAnchorRoute(method, path, body, {
					resolveTtsKey: async () => {
						const fromBrowser = parseKeyHeaders(req.headers).mimo;
						if (fromBrowser) return fromBrowser;
						try {
							const v = await ctx.credentials.resolve("mimo-api-key");
							if (v && typeof v === "string" && v.length > 0) return v;
						} catch {}
						if (process.env.MIMO_API_KEY) return process.env.MIMO_API_KEY;
						throw new Error("还没有填配音用的 Key：「口播」需要 MiMo 的 Key，请到「设置」里填 MiMo 那一行。");
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/bgvideo/file")) {
				const segs = decodeURIComponent(path.slice(30).replace(/^\//, "")).split("/").filter((x) => x && x !== "." && x !== "..");
				const file = join(dataRoot(), "bgvideo", ...segs);
				if (!existsSync(file)) {
					textResponse(res, 404, "file not found");
					return;
				}
				serveMediaFile(req, res, file);
				return;
			}
			if (path.startsWith("/agnes-studio/api/bgvideo")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleBgVideoRoute(method, pathWithQuery, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/mv/file")) {
				const segs = decodeURIComponent(path.slice(25).replace(/^\//, "")).split("/").filter((x) => x && x !== "." && x !== "..");
				const file = join(dataRoot(), "mv", ...segs);
				if (!existsSync(file)) {
					textResponse(res, 404, "file not found");
					return;
				}
				serveMediaFile(req, res, file);
				return;
			}
			if (path.startsWith("/agnes-studio/api/mv")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleMvRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/novel-split")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleNovelSplitRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/deai")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleDeaiRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/media/")) {
				const parts = path.slice(24).split("/").map(decodeURIComponent);
				let file = null;
				if (parts[0] === "anchor" && parts.length >= 3) file = resolveAnchorMedia(parts[1], parts.slice(2).join("/"));
				else if (parts.length >= 2) file = resolveDramaMedia(parts[0], parts.slice(1).join("/"));
				if (!file) {
					textResponse(res, 404, "media not found");
					return;
				}
				serveMediaFile(req, res, file);
				return;
			}
			if (path.startsWith("/agnes-studio/api/library")) {
				const raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = raw ? JSON.parse(raw) : {};
				} catch {
					body = {};
				}
				if (method === "POST" && path.endsWith("/save")) {
					const b = body;
					try {
						jsonResponse(res, 200, {
							success: true,
							...await saveToLibrary(String(b.url || ""), String(b.kind || "image"), b.name ? String(b.name) : void 0)
						});
					} catch (e) {
						jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
					}
					return;
				}
				if (method === "POST" && path.endsWith("/delete")) {
					const rel = String(body.path || "");
					if (!rel) {
						jsonResponse(res, 400, { error: "缺少 path" });
						return;
					}
					try {
						deleteLibraryItem(rel);
						jsonResponse(res, 200, { success: true });
					} catch (e) {
						jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
					}
					return;
				}
				const result = await handleLibraryRoute(method, pathWithQuery);
				if (result) {
					const d = result.data;
					if (result.status === 200 && d && typeof d.file === "string" && (pathWithQuery.includes("/library/thumb") || pathWithQuery.includes("/library/file")) && existsSync(String(d.file))) {
						serveMediaFile(req, res, String(d.file));
						return;
					}
					jsonResponse(res, result.status, result.data);
					return;
				}
			}
			if (path.startsWith("/agnes-studio/api/slice/file")) {
				const segs = decodeURIComponent(path.slice(28).replace(/^\//, "")).split("/").filter((x) => x && x !== "." && x !== "..");
				const file = join(dataRoot(), "slice", ...segs);
				if (!existsSync(file)) {
					textResponse(res, 404, "not found");
					return;
				}
				serveMediaFile(req, res, file);
				return;
			}
			if (path.startsWith("/agnes-studio/api/slice")) {
				const raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = raw ? JSON.parse(raw) : {};
				} catch {
					body = {};
				}
				const result = await handleSliceRoute(method, pathWithQuery, body);
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			}
			if (path.startsWith("/agnes-studio/api/assets")) {
				const remote = String(req.socket && req.socket.remoteAddress || "");
				const isLocal = remote === "" || remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
				const mode = (() => {
					const m = String(process.env.ASSETS_MODE || "").toLowerCase();
					if (m === "thumbs" || m === "public" || m === "local") return m;
					return process.env.ASSETS_ALLOW_REMOTE === "1" ? "public" : "local";
				})();
				if (!isLocal) {
					if (mode === "local") {
						jsonResponse(res, 403, {
							error: "素材库默认只允许本机访问：这些素材来自付费素材包，公开分发属于未授权分发",
							hint: "想让公开访客也能看：设 ASSETS_MODE=thumbs（只能看缩略图）或 ASSETS_MODE=public（完全公开）"
						});
						return;
					}
					if (mode === "thumbs" && path.includes("/assets/file")) {
						jsonResponse(res, 403, {
							error: "原文件仅本机可取（当前 ASSETS_MODE=thumbs，公开访客只能看缩略图）",
							hint: "要放开原文件请设 ASSETS_MODE=public"
						});
						return;
					}
				}
				const remoteUrl = String(process.env.ASSETS_URL || "").trim();
				if (remoteUrl) {
					const tail = pathWithQuery.slice(24);
					const target = remoteUrl.replace(/\/+$/, "") + tail;
					try {
						const rr = await fetch(target, {
							headers: { accept: String(req.headers.accept || "*/*") },
							signal: AbortSignal.timeout(18e4)
						});
						const buf = Buffer.from(await rr.arrayBuffer());
						res.writeHead(rr.status, {
							"Content-Type": rr.headers.get("content-type") || "application/octet-stream",
							"Content-Length": String(buf.length),
							"Cache-Control": "no-store"
						});
						res.end(buf);
					} catch (e) {
						jsonResponse(res, 502, {
							error: "连不上远端素材服务：" + (e instanceof Error ? e.message : String(e)),
							url: target,
							hint: "确认 ASSETS_URL 指向的素材服务在运行，且这台机器能访问到它"
						});
					}
					return;
				}
				const configured = String(process.env.ASSETS_DIR || "").split(":").map((x) => x.trim()).filter(Boolean);
				if (!configured.length) {
					jsonResponse(res, 200, {
						success: true,
						configured: false,
						message: "还没有配置素材库",
						hint: "在 .env 里二选一：ASSETS_DIR 指向本机素材目录（多个用 : 分隔），或 ASSETS_URL 指向另一个素材服务，然后重启",
						example: "ASSETS_DIR=/my/assets:/another/assets   或   ASSETS_URL=http://192.168.1.9:18999/agnes-studio/api/assets"
					});
					return;
				}
				const result = await handleAssetsRoute(method, pathWithQuery, {
					roots: configured.map((p) => ({
						name: basename(p) || p,
						path: p
					})),
					thumbDir: join(dataRoot(), "asset-thumbs"),
					mode
				});
				if (result) {
					const d = result.data;
					if (result.status === 200 && d && typeof d.file === "string" && (path.includes("/assets/thumb") || path.includes("/assets/file")) && existsSync(String(d.file))) {
						serveMediaFile(req, res, String(d.file));
						return;
					}
					jsonResponse(res, result.status, result.data);
					return;
				}
			}
			if (path.startsWith("/agnes-studio/api/toolbox/file")) {
				const segs = decodeURIComponent(path.slice(30).replace(/^\//, "")).split("/").filter((x) => x && x !== "." && x !== "..");
				const file = join(dataRoot(), "toolbox", "vidbee", ...segs);
				if (!existsSync(file)) {
					textResponse(res, 404, "file not found");
					return;
				}
				serveMediaFile(req, res, file);
				return;
			}
			if (path.startsWith("/agnes-studio/api/toolbox")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleToolboxRoute(method, pathWithQuery, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/cover")) {
				try {
					const __raw = method === "POST" ? await readBody(req) : "";
					let body = {};
					try {
						body = __raw ? JSON.parse(__raw) : {};
					} catch {
						body = {};
					}
					const sub = path.slice(23).replace(/^\//, "");
					if (method === "GET" && sub === "styles") {
						jsonResponse(res, 200, { styles: COVER_STYLES.map((s) => ({
							key: s.key,
							name: s.name
						})) });
						return;
					}
					if (method === "POST" && sub === "parse") {
						const result = analyzeNovelFile(String(body?.filename ?? "novel.txt"), String(body?.content ?? ""));
						if (!result.ok) {
							jsonResponse(res, 400, { error: result.error });
							return;
						}
						jsonResponse(res, 200, { meta: result.meta });
						return;
					}
					if (method === "POST" && sub === "build") {
						const meta = {
							title: String(body?.title ?? "").trim(),
							author: String(body?.author ?? "").trim(),
							summary: String(body?.summary ?? "").trim(),
							charCount: 0,
							source: ""
						};
						if (!meta.title) {
							jsonResponse(res, 400, { error: "缺少书名" });
							return;
						}
						jsonResponse(res, 200, { prompt: buildCoverPrompt(meta, String(body?.style ?? ""), String(body?.extra ?? "")) });
						return;
					}
					jsonResponse(res, 404, { error: "not found" });
				} catch (e) {
					jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				}
				return;
			}
			if (path.startsWith("/agnes-studio/api/video")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleVideoparseRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/vpt")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleVptRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/wechat")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleWechatRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path.startsWith("/agnes-studio/api/localfiles")) try {
				const __raw = method === "POST" ? await readBody(req) : "";
				let body = {};
				try {
					body = __raw ? JSON.parse(__raw) : {};
				} catch {
					body = {};
				}
				const result = await handleLocalfilesRoute(method, path, body, {
					resolveKey: async (vendor) => {
						if (vendor === "ollama") return "ollama";
						return resolveApiKeyForVendor(ctx, vendor);
					},
					call: async (vendor, endpoint, opts = {}) => {
						const apiKey = await resolveApiKeyForVendor(ctx, vendor);
						const url = buildUpstreamUrl(getVendorBaseUrl(vendor), endpoint);
						const upstreamMethod = opts.method === "GET" ? "GET" : "POST";
						return vendorFetch(url, {
							method: upstreamMethod,
							headers: {
								Authorization: `Bearer ${apiKey}`,
								"Content-Type": "application/json"
							},
							body: upstreamMethod === "GET" ? void 0 : JSON.stringify(opts.body ?? {}),
							timeoutMs: opts.timeoutMs || 12e4
						});
					}
				});
				if (result) {
					jsonResponse(res, result.status, result.data);
					return;
				}
			} catch (e) {
				jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				return;
			}
			if (path === "/agnes-studio/api/ffmpeg") {
				try {
					jsonResponse(res, 200, await ffmpegStatus());
				} catch (e) {
					jsonResponse(res, 200, {
						available: false,
						hint: e instanceof Error ? e.message : String(e)
					});
				}
				return;
			}
			if (path.startsWith("/agnes-studio/api/prompt-expert")) {
				try {
					const expertResult = await handlePromptExpertRoute(method, path, method === "POST" ? JSON.parse(await readBody(req)) : {}, (v) => v === "ollama" ? Promise.resolve("ollama") : resolveApiKeyForVendor(ctx, v), getVendorFromModel);
					if (expertResult) jsonResponse(res, expertResult.status, expertResult.data);
					else textResponse(res, 405, "method not allowed");
				} catch (e) {
					jsonResponse(res, 500, { error: e instanceof Error ? e.message : String(e) });
				}
				return;
			}
			textResponse(res, 404, "not found");
		};
		return ctx.webServer.register({
			kind: "prefix",
			path: "/agnes-studio/api",
			handler
		});
	}, "dsh-agnes-studio: api-proxy");
	ctx.effect(() => ctx.systemPrompt.section({
		name: "plugin:dsh-agnes-studio",
		order: SECTION_ORDER,
		text: AGNES_STUDIO_GUIDANCE
	}), "dsh-agnes-studio: prompt section");
}
/** 从请求头解析「厂商 → Key」表。前端每个请求都带上它。 */
function parseKeyHeaders(headers) {
	const out = {};
	for (const [id, v] of Object.entries(deviceVendors())) if (v.apiKey) out[id] = v.apiKey;
	const raw = headers["x-vendor-keys"];
	if (typeof raw !== "string" || raw.length === 0) return out;
	try {
		const parsed = JSON.parse(raw);
		if (parsed === null || typeof parsed !== "object") return out;
		for (const [k, v] of Object.entries(parsed)) if (typeof v === "string" && v.trim().length > 0) out[k] = v.trim();
		return out;
	} catch {
		return out;
	}
}
/**
* 造一个假的 ctx 让原 apply() 跑起来，并捕获它注册的 handler。
*
* 这样做的价值：原插件那 1000 行路由分发（15 个 API 分区、断点续跑、
* 素材解析、ffmpeg 调用……）**一行都不用改**，改造面只剩凭据来源一处。
*/
function createHostHandler() {
	mergeDeviceVendors();
	let captured;
	apply({
		effect: (fn) => {
			try {
				fn();
			} catch (error) {
				console.error("[engines] effect 执行失败：", error);
			}
		},
		webServer: { register: (spec) => {
			if (typeof spec?.handler === "function") captured = spec.handler;
			return () => {};
		} },
		systemPrompt: { section: () => () => {} },
		credentials: { 
		/**
		* 解析一个凭据：先看当前请求带的 Key 表，再回落服务端 .env。
		* @param name - 形如 `agnes-api-key`、`mimo-api-key`、`wechat-app-secret`。
		*/
resolve: async (name) => {
			const keys = requestStore.getStore()?.keys ?? {};
			const vendor = String(name).replace(/-api-key$/, "");
			if (keys[vendor]) return keys[vendor];
			const envName = String(name).toUpperCase().replace(/-/g, "_");
			return process.env[envName];
		} }
	});
	if (captured === void 0) throw new Error("[engines] 未能捕获插件注册的 handler");
	return captured;
}
//#endregion
export { apply, buildUpstreamUrl, createHostHandler, inject, name, parseKeyHeaders, requestStore };

/// 「本地大模型启动失败，到底为什么」—— 这是用户 2026-10-11 报的第 2 条。
///
/// ## 为什么必须有这个测试
///
/// 用户原话：「点选本地大模型目前显示本地服务没起来」。查下来是两个问题叠在一起：
///
/// 1. **llama.cpp 那条路**：界面只显示兜底文案，真正的原因（引擎文件不在 /
///    模型文件不在 / 端口都试过 / 进程退出）虽然记在 `LocalModelServer.lastError`
///    里，但**界面根本没读它** —— 0.61 已改成把原因带出来（`本地服务没起来：{原因}`）。
/// 2. **litert-lm（Gemma 4 的 `.litertlm`）那条路**：**一处都没写 `lastError`** ——
///    于是这类模型起不来时，界面拿到的永远是 null，只能显示那句
///    「本地服务没起来（详见运行日志）」。**这就是用户看到的那句话。**
///
/// 第 2 个 bug 的形态特别隐蔽：少写一行赋值，编译器不报错、运行期不抛错，
/// 只有用户真机上起不来时才暴露，而且暴露出来的还是"没有信息"。
/// 所以把"失败 → 一句人话"抽成纯函数 [LocalModelServer.litertStartReason]
/// 并在这里钉住：**每一种失败形态都必须给出一句有信息量的原因**。
library;

import 'package:dsh_mobile/local/local_model_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('litert-lm 启动失败的原因（必须给出一句人话，不能是 null）', () {
    test('原生层没返回端口 → 说清"引擎没起来"并给方向，而不是只说"没起来"', () {
      final r = LocalModelServer.litertStartReason(noPort: true);
      expect(r, contains('litert-lm'));
      expect(r, contains('端口'));
      // 要有"可能是什么 / 该看哪里"，否则等于没说
      expect(r, anyOf(contains('不兼容'), contains('内存')));
      expect(r, contains('运行日志'));
    });

    test('原生层给了原因（缺库/显存不够/模型文件不对）→ 原样带出来，不吞掉', () {
      const native = 'LiteRtLmJniException: dlopen failed: library "libLiteRt.so" not found';
      final r = LocalModelServer.litertStartReason(nativeMessage: native);
      expect(r, contains('LiteRtLmJniException'));
      expect(r, contains('libLiteRt.so'),
          reason: '真机上唯一有价值的线索就是原生那句原话，绝不能只留类名');
    });

    test('原生层没给原因 → 也要有一句，并指向运行日志', () {
      expect(LocalModelServer.litertStartReason(nativeMessage: '   '),
          contains('运行日志'));
      expect(LocalModelServer.litertStartReason(), contains('运行日志'));
    });

    test('GPU 和 CPU 都失败 → 两句原因都要在（否则用户以为"换了 CPU 还是同样的错"）', () {
      final r = LocalModelServer.litertStartReason(
        nativeMessage: 'LiteRtLmJniException: GPU delegate 初始化失败',
        backendLabel: 'GPU（Vulkan）',
        cpuReason: 'litert-lm 启动失败：OutOfMemoryError',
      );
      expect(r, contains('GPU'));
      expect(r, contains('GPU delegate 初始化失败'));
      expect(r, contains('CPU'));
      expect(r, contains('OutOfMemoryError'));
    });

    test('CPU 那次的原因为空 → 不留一个空括号给用户看', () {
      final r = LocalModelServer.litertStartReason(
        nativeMessage: 'boom',
        backendLabel: 'GPU（Vulkan）',
        cpuReason: '  ',
      );
      expect(r, contains('boom'));
      expect(r, isNot(contains('（）')));
      expect(r, isNot(contains('（)')));
    });

    test('任何形态都不许返回空串或 null —— 界面拿它当"有原因"的判据', () {
      final cases = <String>[
        LocalModelServer.litertStartReason(noPort: true),
        LocalModelServer.litertStartReason(nativeMessage: 'x'),
        LocalModelServer.litertStartReason(),
        LocalModelServer.litertStartReason(nativeMessage: 'x', backendLabel: 'GPU', cpuReason: 'y'),
      ];
      for (final c in cases) {
        expect(c.trim(), isNotEmpty,
            reason: '空串会让界面退回那句没信息量的兜底文案，等于这个 bug 又回来了');
      }
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 2026-10-12 追加：**"本地大模型完全用不了"的根因回归测试**
  //
  // 用户原话：「本地大模型依然无法使用」。他 00:09 的真机报告里，00:04:55 起
  // 连续 7 次：
  //   引擎不存在：…/lib/arm64/libllamaserver.so（模型要的是 litert-lm）
  //
  // 括号里那句"模型要的是 litert-lm"是代码自己打印的 —— 等于当场自证：
  // **拿 llama.cpp 的 .so 去判一个 litert-lm 模型**。因为
  // `executablePath` 直接拼常量 `executableName = 'libllamaserver.so'`，
  // 而 llama.cpp 自 0.47 起不随包 → 这个文件永远不存在 → **每个模型**都在那行
  // 返回 null，`litert-lm` 分支根本走不到。
  //
  // 这个 bug 的形状：**代码一行没错、编译不报错、测试全绿**，只有真机上
  // "什么都起不来"。所以必须把"引擎 → 文件名"这个映射钉死。
  // ══════════════════════════════════════════════════════════════════════════
  group('引擎 → 该查哪个 .so（2026-11-03 起只认 MNN）', () {
    test('mnn 查 libmnn_mini_server.so', () {
      expect(LocalModelServer.engineLibName('mnn'), 'libmnn_mini_server.so');
    });

    test('已下线的两个引擎 → null（不许再拿别的引擎的文件硬判）', () {
      // 这正是用户日志里那个 bug 的根：拿 A 引擎的文件去判 B 引擎的模型，
      // 结果「引擎不存在」永远成立。下线之后必须是 null，让调用方给一句人话。
      expect(LocalModelServer.engineLibName('llama.cpp'), isNull);
      expect(LocalModelServer.engineLibName('litert-lm'), isNull);
      expect(LocalModelServer.engineLibName('vllm'), isNull);
      expect(LocalModelServer.engineLibName(''), isNull);
    });

    test('认不出的引擎 → null', () {
      expect(LocalModelServer.engineLibName('gguf'), isNull);
    });

    test('hasEngine：引擎目录为空时一律 false（不猜）', () {
      final s = LocalModelServer.instance;
      // 没 configure 过 → _nativeLibDir 为空 → 任何引擎都算"没有"
      expect(s.hasEngine('mnn'), isFalse);
      expect(s.hasEngine('llama.cpp'), isFalse);
      expect(s.hasEngine('vllm'), isFalse);
    });
  });
}

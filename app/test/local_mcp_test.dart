import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/local/dsh_runtime.dart';
import 'package:dsh_mobile/local/local_mcp.dart';

/// 造一个**只带路径**的 DshRuntime（测试不需要真的运行时）。
DshRuntime _runtime({
  String nodeBinary = '/data/app/~~x/com.dsh/app_arm64/libnode.so',
  String filesDir = '/data/user/0/com.dsh/files',
  String nativeLibDir = '/data/app/~~x/com.dsh/app_arm64',
  String nodeHome = '/data/user/0/com.dsh/files/dsh',
}) {
  return DshRuntime(<String, dynamic>{
    'nodeBinary': nodeBinary,
    'filesDir': filesDir,
    'nativeLibDir': nativeLibDir,
    'nodeHome': nodeHome,
  });
}

void main() {
  group('本地 MCP（stdio）挂载形状', () {
    test('不带 type 字段 —— 带了就变成 http，运行时只认 http/stdio 两种', () {
      final servers = LocalMcp.mcpServers(runtime: _runtime());
      expect(servers, hasLength(1));
      expect(servers.first.containsKey('type'), isFalse,
          reason: 'type 一旦存在就是 http 语义；stdio 靠"没有 type"来区分');
    });

    test('command 必须是绝对路径 —— 相对路径会被运行时直接拒掉整个会话', () {
      final cmd = LocalMcp.mcpServers(runtime: _runtime()).first['command'] as String;
      expect(cmd, startsWith('/'));
      expect(cmd, endsWith('libnode.so'),
          reason: 'Android 上 App 数据目录里的文件不能被执行，只有 nativeLibraryDir 里的能');
    });

    test('args 指向工具箱里的脚本（和 office-zip 同目录，相对 import 才解析得到）', () {
      final args = LocalMcp.mcpServers(runtime: _runtime()).first['args'] as List;
      expect(args, hasLength(1));
      final script = args.first as String;
      expect(script, endsWith('/toolbox/mcp-office.mjs'));
      expect(script, contains('/toolbox/'),
          reason: '必须和 office-zip.mjs / read-xlsx.mjs 落在同一个目录');
    });

    test('env 是有序的 name/value 条目数组（不是普通 map）', () {
      final env = LocalMcp.mcpServers(runtime: _runtime()).first['env'] as List;
      expect(env, isNotEmpty);
      for (final e in env) {
        expect(e, isA<Map>());
        expect((e as Map).keys, containsAll(<String>['name', 'value']));
        expect(e['name'], isA<String>());
        expect(e['value'], isA<String>());
      }
      // PATH 得在（node 要能找到 /system/bin 下的东西）
      final names = env.map((e) => (e as Map)['name'] as String).toSet();
      expect(names, contains('PATH'));
      expect(names, contains('LD_LIBRARY_PATH'));
    });

    test('⚠️ env 里绝不能带 API Key（工具进程是模型可调用的面）', () {
      final env = LocalMcp.mcpServers(runtime: _runtime()).first['env'] as List;
      final names = env.map((e) => (e as Map)['name'] as String).toSet();
      for (final forbidden in <String>[
        'DEEPSEEK_API_KEY',
        'COM_API_KEY',
        'OPENAI_API_KEY',
        'AGNES_API_KEY',
        'ROTATE_API_KEY',
      ]) {
        expect(names.contains(forbidden), isFalse,
            reason: '$forbidden 不该出现在 MCP 子进程的环境里');
      }
    });

    test('运行时就绪信息缺失 → 干脆不挂（不挂总比挂错强）', () {
      final servers = LocalMcp.mcpServers(runtime: _runtime(nodeBinary: ''));
      expect(servers, isEmpty);
    });
  });
}

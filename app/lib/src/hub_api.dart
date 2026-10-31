import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class HubApi {
  HubApi({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;

  Uri _uri(String path, [Map<String, String>? query]) {
    var base = baseUrl.trim();
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    final uri = Uri.parse(base);
    var p = uri.path.replaceAll(RegExp(r'/+$'), '');
    p = '$p$path';
    return uri.replace(
      path: p.isEmpty ? path : p,
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Future<void> health() async {
    final res = await http
        .get(_uri('/api/health'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('hub ответил ${res.statusCode}');
    }
  }

  Future<List<HubInstance>> instances() async {
    final res = await http
        .get(_uri('/api/instances', {'probe': '1'}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception('Неверный токен');
    }
    if (res.statusCode != 200) {
      throw Exception('hub ответил ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(HubInstance.fromJson)
        .toList();
  }

  Future<String> createInstance(String workspacePath) async {
    final res = await http
        .post(
          _uri('/api/instances'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'workspacePath': workspacePath}),
        )
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) {
      throw Exception('Не удалось создать сессию: ${res.statusCode} ${res.body}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    return (data as Map<String, dynamic>)['id']?.toString() ?? '';
  }
}

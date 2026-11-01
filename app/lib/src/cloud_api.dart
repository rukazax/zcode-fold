import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// ZCode cloud API (zcode.z.ai) used by the 3.17 mobile pairing flow.
class ZcodeCloudApi {
  ZcodeCloudApi({required this.jwt});

  final String jwt;

  Uri _uri(String path) => Uri.parse('https://zcode.z.ai$path');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      };

  /// The terminal token: {"token": "...", "expire...": ...}
  /// Mirrors the web client's `options.token(jwt, signal)`.
  Future<String> mintToken() async {
    final res = await http
        .post(
          _uri('/api/v1/remote/token'),
          headers: _headers,
          body: jsonEncode({'role': 'terminal'}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) {
      throw const TokenExpired();
    }
    if (res.statusCode != 200) {
      throw Exception('remote/token ответил ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    // Cloud gateway wraps: {code:0, data:{token: "..."}} or flat.
    final inner = data is Map && data['data'] is Map
        ? (data['data'] as Map).cast<String, dynamic>()
        : (data is Map ? data.cast<String, dynamic>() : const {});
    final token = inner['token'] ?? inner['device_token'] ?? inner['sid'];
    if (token is! String || token.trim().isEmpty) {
      throw Exception('token mint: нет token в ответе: ${res.body.slice(0, 200)}');
    }
    return token.trim();
  }

  /// Computer list for the signed-in account.
  Future<List<Map<String, dynamic>>> devices() async {
    final res = await http
        .get(_uri('/api/v1/remote/device'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) throw const TokenExpired();
    if (res.statusCode != 200) {
      throw Exception('remote/device ответил ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final inner = data is Map && data['data'] is List
        ? (data['data'] as List)
        : data is List
            ? data
            : const [];
    return inner
        .whereType<Map>()
        .map((m) => (m).cast<String, dynamic>())
        .toList();
  }
}

class TokenExpired implements Exception {
  const TokenExpired();
  @override
  String toString() => 'token-expired';
}

extension _Slice on String {
  String slice(int start, int end) {
    final s = start < 0 ? 0 : start;
    final e = end > length ? length : end;
    if (s >= e) return '';
    return substring(s, e);
  }
}

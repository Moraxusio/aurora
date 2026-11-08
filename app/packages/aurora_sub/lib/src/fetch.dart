import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

/// Why a subscription could not be fetched. The message is safe to show: it
/// never contains the URL, which holds the account's key (D-84).
class FetchError implements Exception {
  final String message;
  FetchError(this.message);
  @override
  String toString() => message;
}

/// The largest subscription read. A real one is tens of kilobytes; a page that
/// is far larger is not a subscription, and reading it all is a way to hang.
const maxSubscriptionBytes = 8 << 20;

/// Downloads a subscription. Only http and https are fetched. Redirects are
/// followed, because providers use them. The User-Agent names Clash Meta,
/// since many providers decide what to send (a Clash file, or a link list) from
/// it, and a client they do not recognise is often sent a page instead.
///
/// [client] is for tests. A client made here follows the system's proxy
/// settings (HTTP_PROXY and HTTPS_PROXY), as a browser would: a subscription
/// address is often only reachable that way.
Future<String> fetchSubscription(Uri url, {HttpClient? client, Duration timeout = const Duration(seconds: 20)}) async {
  if (url.scheme != 'http' && url.scheme != 'https') {
    throw FetchError('订阅地址必须以 http:// 或 https:// 开头');
  }
  if (url.host.isEmpty) throw FetchError('订阅地址缺少主机名');
  final c = client ?? HttpClient();
  c.connectionTimeout = timeout;
  c.userAgent = 'clash.meta Aurora/3';
  try {
    return await _get(c, url).timeout(timeout, onTimeout: () => throw FetchError('下载订阅超时（${timeout.inSeconds} 秒）'));
  } on FetchError {
    rethrow;
  } on SocketException catch (e) {
    throw FetchError('连不上订阅服务器：${e.osError?.message ?? e.message}');
  } on HandshakeException {
    throw FetchError('订阅服务器的 HTTPS 证书无法验证');
  } on TlsException {
    throw FetchError('订阅服务器的 HTTPS 证书无法验证');
  } on HttpException catch (e) {
    // e.message, never e.toString(): the exception's text ends with "uri = <the
    // address>", which holds the account key. The test pins this.
    throw FetchError('订阅下载失败：${e.message}');
  } on ArgumentError {
    // a redirect to an address with no host (file:///..) reaches here
    throw FetchError('订阅服务器把请求转到了无法访问的地址');
  } finally {
    if (client == null) c.close(force: true);
  }
}

Future<String> _get(HttpClient c, Uri url) async {
  final req = await c.getUrl(url);
  final res = await req.close();
  if (res.statusCode != 200) {
    await res.drain<void>();
    throw FetchError(switch (res.statusCode) {
      401 || 403 => '订阅服务器拒绝了请求（${res.statusCode}）：订阅链接可能已失效，或被限制了客户端',
      404 => '订阅链接不存在（404）：可能已过期或被重置',
      429 => '请求太频繁（429）：稍后再试',
      final s when s >= 500 => '订阅服务器出错（$s）',
      final s => '订阅服务器返回了 $s',
    });
  }
  final len = res.contentLength;
  if (len > maxSubscriptionBytes) {
    await res.drain<void>();
    throw FetchError('订阅内容太大（${len ~/ 1024} KB），不像是订阅');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in res) {
    bytes.add(chunk);
    if (bytes.length > maxSubscriptionBytes) throw FetchError('订阅内容太大，不像是订阅');
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

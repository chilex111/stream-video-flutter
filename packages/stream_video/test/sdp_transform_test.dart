import 'dart:convert';

import 'package:stream_video/src/sdp-transform/models.dart';
import 'package:test/test.dart';

//given a list split the list into sublists at at given indexes
List<List<T>> splitAt<T>(List<T> list, List<int> indexes) {
  var result = <List<T>>[];
  var start = 0;
  for (var index in indexes) {
    result.add(list.sublist(start, index));
    start = index;
  }
  result.add(list.sublist(start));
  return result;
}

void main() {
  test('splitAt', () {
    final list = [
      "v",
      "o",
      "s",
      "t",
      "c",
      "a",
      "a",
      "a",
      "m",
      "a",
      "a",
      "a",
      "a",
      "a",
      "a",
      "m",
      "a",
      "a",
      "a",
      "a",
      "a",
      "a"
    ];
    expect([
      ['v', 'o', 's', 't', 'c', 'a', 'a', 'a'],
      ['m', 'a', 'a', 'a', 'a', 'a', 'a'],
      ['m', 'a', 'a', 'a', 'a', 'a', 'a']
    ], splitAt(list, [8, 15]));
  });
  test('mediaIndexes', () {
    final list = [
      "v",
      "o",
      "s",
      "t",
      "c",
      "a",
      "a",
      "a",
      "m",
      "a",
      "a",
      "a",
      "a",
      "a",
      "a",
      "m",
      "a",
      "a",
      "a",
      "a",
      "a",
      "a"
    ];
    final mediaIndexes = [];
    list.asMap().forEach((i, el) {
      if (el == "m") {
        mediaIndexes.add(i);
      }
    });
    expect(mediaIndexes, [8, 15]);
  });
  test('Pass it an unprocessed SDP string. give you a ParsedSdp', () {
    const sdpStr = """v=0\r\n\
o=- 20518 0 IN IP4 203.0.113.1\r\n\
s= \r\n\
t=0 0\r\n\
c=IN IP4 203.0.113.1\r\n\
a=ice-ufrag:F7gI\r\n\
a=ice-pwd:x9cml/YzichV2+XlhiMu8g\r\n\
a=fingerprint:sha-1 42:89:c5:c6:55:9d:6e:c8:e8:83:55:2a:39:f9:b6:eb:e9:a3:a9:e7\r\n\
m=audio 54400 RTP/SAVPF 0 96\r\n\
a=rtpmap:0 PCMU/8000\r\n\
a=rtpmap:96 opus/48000\r\n\
a=ptime:20\r\n\
a=sendrecv\r\n\
a=candidate:0 1 UDP 2113667327 203.0.113.1 54400 typ host\r\n\
a=candidate:1 2 UDP 2113667326 203.0.113.1 54401 typ host\r\n\
m=video 55400 RTP/SAVPF 97 98\r\n\
a=rtpmap:97 H264/90000\r\n\
a=fmtp:97 profile-level-id=4d0028;packetization-mode=1\r\n\
a=rtpmap:98 VP8/90000\r\n\
a=sendrecv\r\n\
a=candidate:0 1 UDP 2113667327 203.0.113.1 55400 typ host\r\n\
a=candidate:1 2 UDP 2113667326 203.0.113.1 55401 typ host\r\n\
""";
    final ls = LineSplitter();
    final lines = ls.convert(sdpStr);
    // final media = lines.asMap().forEach((i, l) {
    //   //  final l = lines[42];
    //   var type = l[0];
    //   var content = l.substring(2);
    //   if (l == "m") {}
    // });
    // expect(actual, matcher)
    final l = lines[42];
    var type = l[0];
    var content = l.substring(2);
    //parse media
    expect(type, 'a');
    expect(content, "candidate:1 2 UDP 2113667326 203.0.113.1 55401 typ host");
  });

  test('ParseCandidate', () {
    final expected_candidate = Candidate(
        foundation: 1,
        component: 2,
        transport: 'UDP',
        priority: 2113667326,
        ip: '203.0.113.1',
        port: 55401,
        type: 'host');
    String str = "candidate:1 2 UDP 2113667326 203.0.113.1 55401 typ host";
    Candidate candidate = parseCandidate(str);

    expect(candidate, expected_candidate);
  });

  test('Parse fmtp', () {
    final expected_fmtps = [
      Fmtp(payload: 97, config: 'profile-level-id=4d0028;packetization-mode=1')
    ];
    String str = "fmtp:97 profile-level-id=4d0028;packetization-mode=1";
    Fmtp fmtp = parseFmtp(str);
    final expected_fmtp = expected_fmtps[0];
    expect(fmtp, expected_fmtp);
  });

  test('Parse RTP', () {
    final expected_rtps = <Rtp>[
      Rtp(payload: 97, codec: 'H264', rate: 90000),
      Rtp(payload: 98, codec: 'VP8', rate: 90000)
    ];
    String str = "rtpmap:97 H264/90000";
    Rtp rtp = parseRtp(str);
    final expected_rtp = expected_rtps[0];
    expect(rtp, expected_rtp);
  });
}

Fmtp parseFmtp(String str) {
  RegExp exp = RegExp(r"^fmtp:(?<payload>\d*) (?<config>[\S| ]*)");
  final match = exp.firstMatch(str);
  final payload = match!.namedGroup('payload');
  final config = match.namedGroup('config');
  return Fmtp(payload: int.parse(payload!), config: config!);
}

Rtp parseRtp(String str) {
  RegExp exp = RegExp(
      r"^rtpmap:(?<payload>\d*) (?<codec>[\w\-.]*)(?:\s*\/(?<rate>\d*)(?:\s*\/(\S*))?)?");
  final match = exp.firstMatch(str);
  final payload = match!.namedGroup('payload');
  final codec = match.namedGroup('codec');
  final rate = match.namedGroup('rate');
  return Rtp(
      payload: int.parse(payload!), codec: 'H264', rate: int.parse(rate!));
}

Candidate parseCandidate(String str) {
  RegExp exp = RegExp(
      r"^candidate:(?<foundation>\S*) (?<component>\d*) (?<transport>\S*) (?<priority>\d*) (?<ip>\S*) (?<port>\d*) typ (?<type>\S*)(?: raddr (?<raddr>\S*) rport (?<rport>\d*))?(?: tcptype (?<tcptype>\S*))?(?: generation (?<generation>\d*))?(?: network-id (?<networkId>\d*))?(?: network-cost (?<networkCost>\d*))?");

  final match = exp.firstMatch(str);
  final foundation = match!.namedGroup('foundation');
  final component = match.namedGroup('component');
  final transport = match.namedGroup('transport');
  final priority = match.namedGroup('priority');
  final ip = match.namedGroup('ip');
  final port = match.namedGroup('port');
  final type = match.namedGroup('type');
  final candidate = Candidate(
      foundation: int.parse(foundation!),
      component: int.parse(component!),
      transport: transport!,
      priority: int.parse(priority!),
      ip: ip!,
      port: int.parse(port!),
      type: type!);
  return candidate;
}

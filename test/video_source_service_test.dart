import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

void main() {
  test('keeps headers captured with a media source', () {
    const source = VideoSource(
      url: 'https://media.example.test/playlist.m3u8',
      offset: 42,
      type: VideoSourceType.online,
      format: VideoSourceFormat.hls,
      httpHeaders: {
        'referer': 'https://player.example.test/watch/1',
        'origin': 'https://player.example.test',
        'user-agent': 'Kazumi test agent',
      },
    );

    expect(source.format, VideoSourceFormat.hls);
    expect(source.httpHeaders['referer'],
        'https://player.example.test/watch/1');
  });

  test('uses empty headers when a source was not sniffed in a WebView', () {
    const source = VideoSource(
      url: 'https://media.example.test/video.mp4',
      offset: 0,
      type: VideoSourceType.cached,
    );

    expect(source.httpHeaders, isEmpty);
  });
}

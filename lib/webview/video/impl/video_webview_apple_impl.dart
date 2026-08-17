import 'dart:async';
import 'dart:collection';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/webview/video/video_source_sniffer.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/media.dart';

class VideoWebviewAppleImpl
    extends VideoWebviewController<PlatformInAppWebViewController> {
  PlatformHeadlessInAppWebView? headlessWebView;
  bool hasInjectedScripts = false;
  bool useLegacyParser = false;

  @override
  Future<void> init() async {
    headlessWebView ??= PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
            source: '''
            function removeLazyLoading() {
              document.querySelectorAll('iframe[loading="lazy"]').forEach(iframe => {
                console.log('Removing lazy loading from:', iframe.src);
                iframe.removeAttribute('loading');
              });
            }
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', removeLazyLoading);
            } else {
              removeLazyLoading();
            }
          ''',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
          ),
        ]),
        initialSettings: InAppWebViewSettings(
          userAgent: getRandomUA(),
          mediaPlaybackRequiresUserGesture: true,
          useOnLoadResource: false,
          cacheEnabled: false,
          isInspectable: false,
          contentBlockers: [
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?devtools-detector\.js",
                  resourceType: [
                    ContentBlockerTriggerResourceType.SCRIPT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(urlFilter: '.*', resourceType: [
                ContentBlockerTriggerResourceType.IMAGE,
              ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?googleads",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?googlesyndication\.com",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?prestrain\.html",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?prestrain%2Ehtml",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                  urlFilter: r"^https?://.+?adtrafficquality",
                  resourceType: [
                    ContentBlockerTriggerResourceType.DOCUMENT,
                  ]),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
          ],
        ),
        onWebViewCreated: (controller) {
          KazumiLogger().i('WebView: created');
          webviewController = controller;
          initEventController.add(true);
        },
        onLoadStart: (controller, url) {
          logEventController.add('started loading: $url');
        },
        onLoadStop: (controller, url) {
          logEventController.add('loading completed: $url');
        },
        onReceivedError: (controller, request, error) {
          KazumiLogger().e(
              'WebView: error: ${error.toString()} - Request: ${request.url}');
        },
      ),
    );
    await headlessWebView?.run();
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    this.useLegacyParser = useLegacyParser;
    if (!hasInjectedScripts) {
      addJavaScriptHandlers(useLegacyParser);
      await addUserScripts(useLegacyParser);
      hasInjectedScripts = true;
    }
    count = 0;
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    videoLoadingEventController.add(true);

    await webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void addJavaScriptHandlers(bool useLegacyParser) {
    logEventController.add('Adding LogBridge handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'LogBridge',
        callback: (args) {
          String message = args[0].toString();
          if (message.contains('about:blank')) {
            return;
          }
          logEventController.add(message);
        });

    logEventController.add('Adding JSBridgeDebug handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'JSBridgeDebug',
        callback: (args) {
          final message = args.isEmpty ? '' : args.first.toString();
          if (!this.useLegacyParser || isVideoSourceLoaded) return;
          final encodedUrl = Uri.encodeFull(message);
          final videoUrl = decodeVideoSource(encodedUrl);
          if (videoUrl != encodedUrl) {
            isIframeLoaded = true;
            isVideoSourceLoaded = true;
            videoLoadingEventController.add(false);
            notifyVideoSourceResolved(videoUrl);
          }
        });
    logEventController.add('Adding VideoBridgeDebug handler');
    webviewController?.addJavaScriptHandler(
        handlerName: 'VideoBridgeDebug',
        callback: (args) {
          final payload = args.isEmpty ? null : args.first;
          if (payload is Map) notifySniffedVideoSource(payload);
        });
  }

  Future<void> addUserScripts(bool useLegacyParser) async {
    final List<UserScript> scripts = [];
    scripts.add(UserScript(
      source: buildVideoSourceSnifferScript(
        "payload => window.flutter_inappwebview.callHandler('VideoBridgeDebug', payload)",
      ),
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
    ));

    logEventController.add('Adding JSBridgeDebug UserScript');
    const String jsBridgeDebugScript = """
        window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
        var iframes = document.getElementsByTagName('iframe');
        window.flutter_inappwebview.callHandler('LogBridge', 'The number of iframe tags is ' + iframes.length);
        for (var i = 0; i < iframes.length; i++) {
            var iframe = iframes[i];
            var src = iframe.getAttribute('src');
            if (src) {
              window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
            }
        }
    """;
    scripts.add(UserScript(
      source: jsBridgeDebugScript,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
      forMainFrameOnly: false,
    ));

    await webviewController?.addUserScripts(
      userScripts: scripts,
    );
  }

  @override
  Future<void> unloadPage() async {
    await webviewController!
        .loadUrl(urlRequest: URLRequest(url: WebUri("about:blank")));
  }

  @override
  Future<void> dispose() async {
    await headlessWebView?.dispose();
    headlessWebView = null;
    webviewController = null;
    disposeEventControllers();
  }
}

/// Builds the page-world media sniffer shared by the InAppWebView backends.
///
/// It deliberately reports only accessible media manifests and direct media
/// URLs. Encrypted keys and MediaSource buffers remain outside the parser.
String buildVideoSourceSnifferScript(String bridgeCall) => r'''
  (() => {
    if (window.__kazumiMediaSnifferInstalled) return;
    window.__kazumiMediaSnifferInstalled = true;

    const candidates = new Map();
    let flushTimer;
    const adPattern = /googleads|googlesyndication|doubleclick|adtrafficquality/i;
    const mediaPattern = /\.(m3u8|mpd|mp4|m4v|webm|mov|mkv)(?:[?#]|$)/i;

    function asAbsoluteUrl(value, base = location.href) {
      try { return new URL(value, base).href; } catch (_) { return ''; }
    }

    function formatFor(url, body) {
      if (/\.m3u8(?:[?#]|$)/i.test(url) || /^\s*#EXTM3U/i.test(body || '')) return 'hls';
      if (/\.mpd(?:[?#]|$)/i.test(url) || /<MPD[\s>]/i.test(body || '')) return 'dash';
      return 'auto';
    }

    function score(candidate) {
      let value = candidate.format === 'hls' ? 60 : candidate.format === 'dash' ? 50 : 30;
      if (/\.(mp4|m4v|webm|mov|mkv)(?:[?#]|$)/i.test(candidate.url)) value += 15;
      if (candidate.url.includes(location.hostname)) value += 5;
      return value;
    }

    function flush() {
      flushTimer = undefined;
      const best = [...candidates.values()].sort((a, b) => score(b) - score(a))[0];
      if (!best) return;
      __KAZUMI_BRIDGE__({
        url: best.url,
        format: best.format,
        headers: {
          referer: location.href,
          origin: location.origin,
          'user-agent': navigator.userAgent,
        },
      });
    }

    function report(value, body) {
      const url = asAbsoluteUrl(value);
      if (!url || adPattern.test(url)) return;
      const format = formatFor(url, body);
      if (format === 'auto' && !mediaPattern.test(url)) return;
      candidates.set(url, { url, format });
      clearTimeout(flushTimer);
      flushTimer = setTimeout(flush, 350);
    }

    function scan(value, depth = 0) {
      if (depth > 4 || value == null) return;
      if (typeof value === 'string') {
        const text = value.trim();
        if (/^#EXTM3U/i.test(text) || /<MPD[\s>]/i.test(text)) return;
        if (mediaPattern.test(text)) report(text);
        return;
      }
      if (Array.isArray(value)) {
        value.slice(0, 40).forEach(item => scan(item, depth + 1));
        return;
      }
      if (typeof value === 'object') {
        Object.values(value).slice(0, 80).forEach(item => scan(item, depth + 1));
      }
    }

    const originalFetch = window.fetch;
    window.fetch = async function(...args) {
      const response = await originalFetch.apply(this, args);
      const clone = response.clone();
      clone.text().then(text => {
        report(response.url || (args[0] && args[0].url) || args[0], text);
        try { scan(JSON.parse(text)); } catch (_) {}
      }).catch(() => {});
      return response;
    };

    const originalOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      this.addEventListener('load', () => {
        try {
          const text = typeof this.responseText === 'string' ? this.responseText : '';
          report(this.responseURL || url, text);
          if (text) scan(JSON.parse(text));
        } catch (_) {}
      });
      return originalOpen.call(this, method, url, ...rest);
    };

    function scanVideo(video) {
      const src = video.currentSrc || video.getAttribute('src');
      if (src && !src.startsWith('blob:')) report(src);
      video.querySelectorAll('source[src]').forEach(source => report(source.src));
    }
    document.querySelectorAll('video').forEach(scanVideo);
    new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(node => {
      if (node.nodeName === 'VIDEO') scanVideo(node);
      if (node.querySelectorAll) node.querySelectorAll('video').forEach(scanVideo);
    }))).observe(document.documentElement, { childList: true, subtree: true });
  })();
'''.replaceAll('__KAZUMI_BRIDGE__', '($bridgeCall)');

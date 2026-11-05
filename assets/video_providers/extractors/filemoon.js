// OpenStream-compatible Filemoon host extractor.
function getInfo() {
  return { id: 'filemoon', name: 'Filemoon', version: '1.0.0',
    hosts: ['filemoon','moonplayer','kerapoxy','bf0skv','fmoonembed','moflix-stream','cinegrab','filemoon.sx','filemoon.to','filemoon.in','moonplayer.com','kerapoxy.com','bf0skv.org','fmoonembed.com','moflix-stream.xyz','cinegrab.com'] };
}
function _absolute(file, base) {
  if (/^https?:\/\//i.test(file)) return file;
  if (file.indexOf('//') === 0) return 'https:' + file;
  return absUrl(file, base);
}
function extract(url, opts) {
  opts = opts || {};
  var headers = Object.assign({ 'User-Agent': 'Mozilla/5.0' }, opts.headers || {});
  return fetch(url, { headers: headers }).then(function(r) {
    var pageUrl = r.url || url, html = r.body || '';
    var iframe = html.match(/<iframe[^>]+src=["']([^"']+)["']/i);
    if (iframe && iframe[1]) {
      var inner = _absolute(iframe[1], pageUrl);
      return fetch(inner, { headers: Object.assign({}, headers, { 'Referer': pageUrl }) })
        .then(function(x) { return { html: x.body || '', pageUrl: x.url || inner }; });
    }
    return { html: html, pageUrl: pageUrl };
  }).then(function(page) {
    var js = unpackJs(page.html);
    var match = js.match(/file\s*:\s*["']([^"']+)["']/i) || js.match(/sources?\s*:\s*\[\s*\{[^}]*file\s*:\s*["']([^"']+)["']/i);
    if (!match) throw new Error('filemoon: no media URL');
    var media = _absolute(match[1], page.pageUrl);
    return [{ url: media, quality: (media.match(/(\d{3,4})p/i) || [])[0] || '720p',
      container: /\.m3u8(?:[?#]|$)/i.test(media) ? 'hls' : 'mp4',
      headers: Object.assign({}, headers, { 'Referer': page.pageUrl }),
      kind: opts.kind || 'unknown', audioLang: opts.audioLang || 'und', subtitles: [] }];
  });
}

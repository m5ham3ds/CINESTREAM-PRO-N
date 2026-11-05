// OpenStream-compatible Vidmoly extractor.
function getInfo() { return { id: 'vidmoly', name: 'Vidmoly', version: '1.0.0', hosts: ['vidmoly','vidmoly.to','vidmoly.net','vidmoly.me'] }; }
function extract(url, opts) {
  opts = opts || {};
  var embed = String(url).replace('/w/', '/embed-');
  if (embed.indexOf('/embed-') >= 0 && !/\.html(?:[?#]|$)/i.test(embed)) embed += '.html';
  var headers = Object.assign({ 'User-Agent': 'Mozilla/5.0' }, opts.headers || {});
  return fetch(embed, { headers: headers }).then(function(r) {
    var html = unpackJs(r.body || '');
    var match = html.match(/file\s*:\s*["']([^"']+\.m3u8[^"']*)["']/i);
    if (!match) throw new Error('vidmoly: no HLS source');
    return [{ url: absUrl(match[1], r.url || embed), quality: 'auto', container: 'hls',
      headers: Object.assign({}, headers, { 'Referer': r.url || embed }), kind: opts.kind || 'unknown',
      audioLang: opts.audioLang || 'und', subtitles: [] }];
  });
}

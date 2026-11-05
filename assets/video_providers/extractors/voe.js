// OpenStream-compatible Voe extractor. The encoded config path mirrors its public player format.
function getInfo() {
  return { id: 'voe', name: 'Voe', version: '1.0.0', hosts: [
    'voe.sx','voe-unblock.com','voe-unblock.net','voe-unblock.org','voeunblock.com','tubelessceliolymph.com',
    'maxfinishseveral.com','crystaltreatmenteast.com','graceaddresscommunity.com','christopheruntilpoint.com','launchreliantcleaverriver.com','jennifercertaindevelopment.com','voe-','voeun','voeunblock','tubelessceliolymph','maxfinishseveral','crystaltreatmenteast','graceaddresscommunity','christopheruntilpoint','launchreliantcleaverriver','jennifercertaindevelopment'
  ] };
}
function _rot13(s) { return String(s).replace(/[a-zA-Z]/g, function(c) { var n = c.charCodeAt(0), base = n <= 90 ? 65 : 97; return String.fromCharCode(((n - base + 13) % 26) + base); }); }
function _decode(s) {
  var junk = ['@$','^^','~@','%?','*~','!!','#&'];
  s = _rot13(s);
  junk.forEach(function(j){ s = s.split(j).join(''); });
  var stage1 = atob(s);
  var shifted = stage1.split('').map(function(c){ return String.fromCharCode(c.charCodeAt(0)-3); }).join('').split('').reverse().join('');
  var config = JSON.parse(atob(shifted));
  return config.source || config.direct_access_url || '';
}
function extract(url, opts) {
  opts = opts || {};
  var headers = Object.assign({ 'User-Agent': 'Mozilla/5.0' }, opts.headers || {});
  return fetch(url, { headers: headers }).then(function(r) {
    var pageUrl = r.url || url, html = r.body || '';
    var redirect = html.match(/window\.location\.href\s*=\s*["'](https?:\/\/[^"']+)["']/i);
    if (redirect) return fetch(redirect[1], { headers: Object.assign({}, headers, { 'Referer': pageUrl }) })
      .then(function(x){ return { html: x.body || '', pageUrl: x.url || redirect[1] }; });
    return { html: html, pageUrl: pageUrl };
  }).then(function(page) {
    var direct = page.html.match(/["']hls["']\s*:\s*["']([^"']+)["']/i);
    var media = direct ? direct[1] : '';
    if (media && media.indexOf('http') !== 0) { try { media = atob(media); } catch(e) {} }
    if (!media) {
      var packed = page.html.match(/<script\s+type=["']application\/json["']>\s*\[?([\s\S]*?)\]?\s*<\/script>/i);
      if (packed) { try { media = _decode(packed[1]); } catch(e) {} }
    }
    if (!media || !/^https?:\/\//i.test(media)) throw new Error('voe: unable to decode stream config');
    return [{ url: media, quality: 'auto', container: 'hls', headers: Object.assign({}, headers, { 'Referer': page.pageUrl }),
      kind: opts.kind || 'unknown', audioLang: opts.audioLang || 'und', subtitles: [] }];
  });
}

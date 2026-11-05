// OpenStream-compatible StreamWish / VidHide player extractor.
function getInfo() {
  return { id: 'streamwish', name: 'StreamWish / VidHide', version: '1.0.0', hosts: [
    'streamwish','wishembed','swdyu','wishfast','sfastwish','strwish','playerwish','hlswish','awish','dwish','embedwish','mwish','flaswish','obeywish','cdnwish','asnwish','jodwish','streamhg','dhcplay','hglink','vidhide','filelions','alions','dlions','mlions','ryderjet','smoothpre','movearnpre','dinisglows','mivalyo','dintezuvio',
    'streamwish.to','streamwish.com','wishembed.pro','swdyu.com','wishfast.top','sfastwish.com','strwish.com','playerwish.com','hlswish.com','awish.pro','dwish.pro','embedwish.com','mwish.pro','flaswish.com','obeywish.com','cdnwish.com','asnwish.com','jodwish.com','streamhg.net','dhcplay.com','hglink.to',
    'vidhide.com','filelions.to','alions.to','dlions.to','mlions.to','vidhidepro.com','vidhidevip.com','vidhidefast.com','ryderjet.com','smoothpre.com','movearnpre.com','dinisglows.com','mivalyo.com','dintezuvio.com'
  ] };;
}
function extract(url, opts) {
  opts = opts || {};
  var embed = String(url).replace('/f/', '/e/').replace('/d/', '/e/');
  var headers = Object.assign({ 'User-Agent': 'Mozilla/5.0' }, opts.headers || {});
  return fetch(embed, { headers: headers }).then(function(r) {
    var html = unpackJs(r.body || '');
    var links = {};
    var re = /["'](hls\d)["']\s*:\s*["']([^"']+)["']/ig, m;
    while ((m = re.exec(html)) !== null) links[m[1]] = m[2];
    var file = links.hls4 || links.hls2 || links.hls3;
    if (!file) {
      var fallback = html.match(/file\s*:\s*["']([^"']+\.m3u8[^"']*)["']/i);
      if (fallback) file = fallback[1];
    }
    if (!file) throw new Error('streamwish: no HLS source');
    var media = absUrl(file, r.url || embed);
    return [{ url: media, quality: (media.match(/(\d{3,4})p/i) || [])[0] || 'auto', container: 'hls',
      headers: Object.assign({}, headers, { 'Referer': r.url || embed }), kind: opts.kind || 'unknown',
      audioLang: opts.audioLang || 'und', subtitles: [] }];
  });
}

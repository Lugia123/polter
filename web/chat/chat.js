/*!
 * Polter group chat page.
 *
 * The page draws messages and owns one scroll position; the host owns the
 * truth (which page is loaded, search hits, link targets, image tickets,
 * theme). The bridge is frozen in CONTRACT.md — change both together.
 *
 * Threading: one document, one scroll container (`#scroll`). Rows are direct
 * children of it and it is `position: relative`, so `row.offsetTop` and
 * `scrollTop` share one coordinate space; that is what the anchor arithmetic
 * below relies on.
 */
(function () {
  'use strict';

  var PROTOCOL = 2;

  // -- strings ------------------------------------------------------------

  var STRINGS = {
    zh: {
      loadingOlder: '正在加载更早…',
      endOfHistory: '到头了',
      jumpLatest: '↓ 跳到最新',
      copy: '复制',
      copied: '已复制',
      image: '图片',
      // The first screen's own states (task 3098). **A slow host is not a
      // dead one**: the ten-second wait says "still reading, you may retry"
      // and the page asks again with a growing delay; only the host's own
      // `error` says "could not read".
      loadingHistory: '正在加载聊天记录…',
      stillLoading: '还在读，可以点这里重试',
      loadFailed: '读不到，点这里重试',
      olderFailed: '更早的记录读不到，点这里重试',
      // The role the speaker wore, short enough for a 104px gutter. A role
      // not in this table is drawn as it came (a plugin's own role is not
      // ours to rename); `supervisor` matches by substring so the prefixed
      // spellings all read the same word.
      role: {
        'polter-supervisor': '总管',
        supervisor: '总管',
        'dev-worker': '开发',
        'test-worker': '测试',
        reviewer: '审核',
        'ui-designer': '设计',
        'polter-writer': '主笔',
        worker: '队友'
      }
    },
    en: {
      loadingOlder: 'Loading earlier…',
      endOfHistory: 'Start of history',
      jumpLatest: '↓ Jump to latest',
      copy: 'Copy',
      copied: 'Copied',
      image: 'Image',
      loadingHistory: 'Loading chat history…',
      stillLoading: 'Still loading. Click to retry',
      loadFailed: "Couldn't read the chat. Click to retry",
      olderFailed: "Couldn't read earlier messages. Click to retry",
      role: {
        'polter-supervisor': 'supervisor',
        supervisor: 'supervisor',
        'dev-worker': 'dev',
        'test-worker': 'test',
        reviewer: 'review',
        'ui-designer': 'design',
        'polter-writer': 'writer',
        worker: 'teammate'
      }
    }
  };

  // -- state --------------------------------------------------------------

  var state = {
    L: STRINGS.zh,
    locale: 'zh',
    follow: true,          // is the viewport pinned to the bottom?
    pending: 0,            // messages arrived below while not following
    loading: false,        // a chat.loadOlder is in flight
    hasEarlier: true,
    resetDone: false,
    rows: Object.create(null),   // id -> row element
    rowList: [],                 // rows in document order
    raw: Object.create(null),    // id -> Message
    anchor: null,                // {el, delta} for resize recovery
    lastW: 0,
    lastH: 0,
    themeVars: [],
    lastReport: '',
    loadTimer: 0,
    // The first screen has not been answered yet (`chat.ready` is out, no
    // `page.reset` has arrived). **Reset by a reset without `error`**, not by
    // any reset: an error reset still leaves the reader with nothing to read,
    // so the retry keeps asking. `bootSettled` is what the retry is guarded
    // on -- re-posting `chat.ready` after a good reset would make the host
    // send a second reset and throw away the position the reader is on.
    bootSettled: false,
    bootDelay: 0,                // ms until the next `chat.ready` retry
    bootTimer: 0,
    // A failure the pill at the top is saying, and what its retry re-sends
    // (`older` -> chat.loadOlder, `boot` -> chat.ready). It outranks the
    // loading/end text until a reset or a prepend clears it.
    topError: null,
    hits: [],                    // ids of search hits, for searchStep()
    hitIndex: -1,
    // Where the reader is, reported to the host (`chat.reading`). The host
    // keeps the last one and remembers it when the group is left; the page
    // does not store it anywhere.
    readingAt: 0,
    readingTimer: 0
  };

  var sc, topEl, topText, jump, jumpLabel, jumpCount;

  var FOLLOW_SLOP = 24;      // §3.4 of the design
  var LOAD_OLDER_AT = 240;   // §3.1 of the design
  var IMAGE_PREFETCH = 8000; // skip auto-detect on very long code blocks
  var READING_EVERY_MS = 200; // chat.reading at most this often while scrolling
  // The first screen's wait (task 3098). 10 s is the host's own reset
  // cadence; a page that never hears back asks again -- 10, 20, 40, then 60 s
  // apart, so a big page on a slow machine is not called dead and a broken
  // host is not hit once per ten seconds. A reader's own retry starts the
  // ladder again at 10 s.
  var BOOT_TIMEOUT_MS = 10000;
  var BOOT_BACKOFF_MAX_MS = 60000;
  var LOAD_OLDER_TIMEOUT_MS = 15000; // CONTRACT.md §4.2

  // -- bridge -------------------------------------------------------------

  function hostPost(type, params) {
    var msg = { type: type };
    if (params) {
      for (var k in params) {
        if (Object.prototype.hasOwnProperty.call(params, k)) msg[k] = params[k];
      }
    }
    try {
      if (window.polter && typeof window.polter.postMessage === 'function') {
        window.polter.postMessage(msg);
        return;
      }
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers.polterChat) {
        window.webkit.messageHandlers.polterChat.postMessage(msg);
        return;
      }
      if (window.chrome && window.chrome.webview &&
          typeof window.chrome.webview.postMessage === 'function') {
        window.chrome.webview.postMessage(msg);
        return;
      }
    } catch (e) {
      // A host that went away mid-call: fall through to the local record,
      // which is also how a standalone dev shell can see what was sent.
    }
    if (window.polterChat) {
      (window.polterChat.sent = window.polterChat.sent || []).push(msg);
    }
  }

  var handlers = {
    'page.reset': onReset,
    'page.prepend': onPrepend,
    'page.append': onAppend,
    'page.update': onUpdate,
    'page.follow': function () { jumpToLatest(); },
    'page.locate': onLocate,
    'page.search': onSearch,
    'page.image': onImage,
    'page.notImage': onNotImage,
    'page.theme': function (m) { applyTheme(m); }
  };

  function receive(data) {
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (e) { return; }
    }
    if (!data || typeof data !== 'object') return;
    // The existing WKScriptMessageHandler bridges post {method, argument};
    // accept that envelope as well as the flat {type, ...} one.
    if (typeof data.method === 'string' && data.type == null) {
      var arg = (data.argument && typeof data.argument === 'object') ? data.argument : {};
      var flat = { type: data.method };
      for (var k in arg) {
        if (Object.prototype.hasOwnProperty.call(arg, k)) flat[k] = arg[k];
      }
      data = flat;
    }
    var h = handlers[data.type];
    if (!h) return;
    try {
      h(data);
    } catch (e) {
      hostPost('chat.error', {
        message: String((e && e.message) || e)
      });
    }
  }

  // -- formatting ---------------------------------------------------------

  function pad2(n) { return n < 10 ? '0' + n : String(n); }

  function dateOf(ms) {
    if (ms == null) return null;
    var d = new Date(ms);
    return isNaN(d.getTime()) ? null : d;
  }

  function fmtTime(ms) {
    var d = dateOf(ms);
    if (!d) return '';
    return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
  }

  function fmtDay(ms) {
    var d = dateOf(ms);
    if (!d) return '';
    return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function roleClass(role) {
    var r = String(role || '').toLowerCase();
    if (r.indexOf('supervisor') >= 0) return 'role-supervisor';
    if (r === 'user' || r === 'human') return 'role-user';
    if (r) return 'role-worker';
    return '';
  }

  // The short word a gutter draws for a role, in the reader's language.
  // Unknown roles are shown as they came: another plugin's role is not this
  // page's to rename, and an empty role is no role at all (the caller draws
  // nothing).
  function roleLabel(role) {
    var raw = String(role || '').trim();
    if (!raw) return '';
    var names = state.L.role || {};
    var r = raw.toLowerCase();
    if (Object.prototype.hasOwnProperty.call(names, r)) return names[r];
    if (r.indexOf('supervisor') >= 0 && names.supervisor) return names.supervisor;
    return raw;
  }

  // -- markdown -----------------------------------------------------------

  function renderMarkdown(text) {
    var src = text == null ? '' : String(text);
    if (!window.marked) return '<p>' + esc(src) + '</p>';
    try {
      // gfm gives tables, strikethrough and task-list checkboxes.
      return window.marked.parse(src, { gfm: true, breaks: false, async: false });
    } catch (e) {
      return '<p>' + esc(src) + '</p>';
    }
  }

  var KILL_TAGS = 'script,iframe,frame,frameset,object,embed,applet,style,link,' +
                  'meta,base,form,button,textarea,select,option';

  // Message text is agent output: it is rendered, not trusted. Scripts do not
  // run when inserted through innerHTML, but inline handlers and positioned
  // overlays would, so they are removed. Known-safe cosmetic HTML (br, kbd,
  // details, task-list checkboxes) survives.
  function sanitize(root) {
    var kill = root.querySelectorAll(KILL_TAGS);
    for (var i = kill.length - 1; i >= 0; i--) kill[i].remove();

    var uses = root.querySelectorAll('svg use');
    for (var u = uses.length - 1; u >= 0; u--) uses[u].remove();

    var els = root.querySelectorAll('*');
    for (var e = 0; e < els.length; e++) {
      var el = els[e];
      if (el.tagName === 'INPUT') {
        var type = (el.getAttribute('type') || '').toLowerCase();
        if (type !== 'checkbox') { el.remove(); continue; }
        el.setAttribute('disabled', '');
      }
      var attrs = el.attributes;
      for (var a = attrs.length - 1; a >= 0; a--) {
        var name = attrs[a].name.toLowerCase();
        var value = attrs[a].value;
        if (name === 'style' || name === 'srcdoc' || name.slice(0, 2) === 'on' ||
            name === 'srcset') {
          el.removeAttribute(attrs[a].name);
          continue;
        }
        if ((name === 'href' || name === 'src' || name === 'xlink:href' ||
             name === 'action') &&
            /^\s*(javascript|vbscript|data:text\/html)/i.test(value)) {
          el.removeAttribute(attrs[a].name);
        }
      }
    }
  }

  function isLoadable(src) {
    return /^(data:image\/|polter-file:|blob:|https?:\/\/)/i.test(String(src || ''));
  }

  // After the markdown is inserted: sanitize, give wide blocks their own
  // scroll box, highlight only fenced code, and put markdown images
  // (`![alt](path)`) on the same ticket path as `images[]`.
  function decorate(body, msg) {
    sanitize(body);
    wrapBlocks(body);
    highlightCode(body);
    var imgs = body.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) prepareImage(imgs[i], msg);
    findPathTokens(body, msg);
  }

  // -- bare paths in the prose ---------------------------------------------
  //
  // **A message that is only a path is drawn as an image or a file link, not
  // as text** (the person's 2026-11-09 ruling: "图片和文件链接由程序解析").
  // The page does not decide whether the path is an image -- it cannot read a
  // file -- so it asks the host (`chat.image`) and swaps the placeholder for
  // whatever the host answers (`page.image` or `page.notImage`).
  //
  // **Only a text node that is entirely one path is a candidate.** A path in
  // the middle of a sentence stays text this round; the inline thumbnail is
  // not built yet and pretending otherwise would need a second layout rule
  // for a case nobody has asked to see.
  //
  // `pre`, `code` and `a` are skipped: an instruction in a code block that
  // happens to start with `/` is a command, not a link.

  var PATH_TOKEN = /^(?:file:\/\/\S+|https?:\/\/\S+|~\/\S+|\/\S+)$/;
  var PATH_TRAIL = /[.,;:!?)\]}>，。；：！？）】」』]+$/;

  function isPathToken(text) {
    var t = String(text || '').trim();
    if (!t) return '';
    t = t.replace(PATH_TRAIL, '');
    if (t === '/' || t.length < 2) return '';
    return PATH_TOKEN.test(t) ? t : '';
  }

  function findPathTokens(body, msg) {
    if (!document.createTreeWalker) return;
    var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        var p = node.parentNode;
        while (p && p !== body) {
          var tag = p.nodeName.toLowerCase();
          if (tag === 'pre' || tag === 'code' || tag === 'a' ||
              tag === 'script' || tag === 'style') {
            return NodeFilter.FILTER_REJECT;
          }
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var token = isPathToken(node.nodeValue);
      if (!token) continue;
      var span = document.createElement('span');
      span.className = 'pathref';
      span.dataset.pathSrc = token;
      span.textContent = token;
      node.parentNode.replaceChild(span, node);
      hostPost('chat.image', { src: token, id: msg ? msg.id : null });
    }
  }

  // The host could not read the path as an image: keep the text, but let it
  // be clicked (the click goes to the host like any link, `chat.openLink`).
  function onNotImage(m) {
    if (!m || !m.src) return;
    var src = String(m.src);
    var cap = capture();
    var hit = false;

    var paths = sc.querySelectorAll('.pathref[data-path-src]');
    for (var i = 0; i < paths.length; i++) {
      var span = paths[i];
      if (span.dataset.pathSrc !== src) continue;
      hit = true;
      span.parentNode.replaceChild(fileLink(src, span.textContent), span);
    }

    // A Markdown image whose file the host says is not an image: the alt
    // text becomes the link, so the message still says what it was.
    var imgs = sc.querySelectorAll('img');
    for (var j = 0; j < imgs.length; j++) {
      var img = imgs[j];
      var isrc = img.dataset.src || img.getAttribute('src') || '';
      if (isrc !== src) continue;
      hit = true;
      img.parentNode.replaceChild(fileLink(src, img.getAttribute('alt') || src), img);
    }

    if (!hit) return;
    if (state.follow) sc.scrollTop = sc.scrollHeight;
    else restore(cap);
    updateAnchor();
  }

  function fileLink(src, label) {
    var a = document.createElement('a');
    a.className = 'filelink';
    a.href = src;
    a.textContent = label || src;
    a.dataset.src = src;
    return a;
  }

  function wrapBlocks(body) {
    var pres = body.querySelectorAll('pre');
    for (var i = 0; i < pres.length; i++) {
      var pre = pres[i];
      if (pre.parentNode && pre.parentNode.classList &&
          pre.parentNode.classList.contains('codeblock')) continue;
      var wrap = document.createElement('div');
      wrap.className = 'codeblock';
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);
      wrap.appendChild(copyButton(pre));
    }
    var tables = body.querySelectorAll('table');
    for (var t = 0; t < tables.length; t++) {
      var table = tables[t];
      if (table.parentNode && table.parentNode.classList &&
          table.parentNode.classList.contains('tablewrap')) continue;
      var tw = document.createElement('div');
      tw.className = 'tablewrap';
      table.parentNode.insertBefore(tw, table);
      tw.appendChild(table);
    }
  }

  function copyButton(pre) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'copy';
    btn.textContent = state.L.copy;
    btn.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      var text = pre.innerText.replace(/\n$/, '');
      hostPost('chat.copy', { text: text });
      btn.textContent = state.L.copied;
      setTimeout(function () { btn.textContent = state.L.copy; }, 1200);
    });
    return btn;
  }

  function highlightCode(root) {
    if (!window.hljs) return;
    var codes = root.querySelectorAll('pre code');
    for (var i = 0; i < codes.length; i++) {
      var code = codes[i];
      var lang = '';
      for (var c = 0; c < code.classList.length; c++) {
        if (code.classList[c].indexOf('language-') === 0) {
          lang = code.classList[c].slice('language-'.length);
          break;
        }
      }
      try {
        if (lang) {
          if (!window.hljs.getLanguage(lang)) continue; // unknown: plain text
        } else if (code.textContent.length > IMAGE_PREFETCH) {
          continue;
        }
        window.hljs.highlightElement(code);
      } catch (e) {
        // Highlighting is cosmetic; a failure leaves the plain code visible.
      }
    }
  }

  // -- images -------------------------------------------------------------

  function addImage(msg, im, body) {
    if (!im || !im.src) return;
    var figure = document.createElement('div');
    figure.className = 'img';
    var img = document.createElement('img');
    img.alt = im.alt || state.L.image;
    if (im.width && im.height) {
      img.width = im.width;
      img.height = im.height;
      img.style.aspectRatio = im.width + ' / ' + im.height;
    } else if (im.width) {
      img.width = im.width;
    }
    prepareImage(img, msg, String(im.src));
    figure.appendChild(img);
    body.appendChild(figure);
  }

  // One path for every image: reserve lazy loading, record the original src
  // for page.image matching, and ask the host for a ticket when the page
  // itself cannot read the path.
  function prepareImage(img, msg, src) {
    if (!img || img.dataset.src) return;
    src = src == null ? (img.getAttribute('src') || '') : src;
    if (!src) return;
    img.decoding = 'async';
    img.loading = 'lazy';
    img.dataset.src = src;
    if (isLoadable(src)) {
      if (!img.getAttribute('src')) img.src = src;
    } else {
      // A local path the page cannot read: the host answers with a ticket
      // URL through page.image (contract). Show a placeholder meanwhile.
      img.removeAttribute('src');
      img.classList.add('pending');
      hostPost('chat.imageTicket', { src: src, id: msg ? msg.id : null });
    }
    img.addEventListener('load', onImageLoad);
  }

  // §3.5: an image that arrived without dimensions grows the document under
  // the reader. If it grew while entirely above the viewport, move the scroll
  // by exactly the growth; if we are following, stay at the bottom.
  function onImageLoad(ev) {
    var img = ev.currentTarget;
    var prev = parseFloat(img.dataset.gh || '0') || 0;
    var now = img.offsetHeight;
    img.dataset.gh = String(now);
    img.classList.remove('pending');
    var delta = now - prev;
    if (!delta) return;
    if (state.follow) {
      sc.scrollTop = sc.scrollHeight;
      return;
    }
    if (img.offsetTop + prev <= sc.scrollTop + 1) {
      sc.scrollTop += delta;
      updateAnchor();
    }
  }

  function measureImages(row) {
    var imgs = row.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      imgs[i].dataset.gh = String(imgs[i].offsetHeight);
    }
  }

  // -- rows ---------------------------------------------------------------

  function renderRow(m) {
    var el = document.createElement('div');
    el.className = 'msg';
    var rc = roleClass(m.role);
    if (rc) el.classList.add(rc);
    if (m.speakerRule) el.classList.add('speaker-rule');
    el.dataset.id = String(m.id);
    if (m.seq != null) el.dataset.seq = String(m.seq);

    var gutter = document.createElement('div');
    gutter.className = 'gutter';
    var time = document.createElement('time');
    time.textContent = fmtTime(m.at);
    var d = dateOf(m.at);
    if (d) time.dateTime = d.toISOString();
    var who = document.createElement('span');
    who.className = 'who';
    who.textContent = m.author == null ? '' : String(m.author);
    gutter.appendChild(time);
    gutter.appendChild(who);
    // The role the speaker wore. The host sends it on the message
    // (`CONTRACT.md` §2.1); a message without one draws no line, which is
    // not the same as a message whose role is "". The word is the reader's
    // language, not the role's wire name.
    var role = roleLabel(m.role);
    if (role) {
      var roleEl = document.createElement('span');
      roleEl.className = 'role';
      roleEl.textContent = role;
      gutter.appendChild(roleEl);
    }

    var body = document.createElement('div');
    body.className = 'body';
    renderBody(body, m);

    el.appendChild(gutter);
    el.appendChild(body);
    return el;
  }

  function renderBody(body, m) {
    body.innerHTML = renderMarkdown(m.text);
    decorate(body, m);
    var images = m.images || [];
    for (var i = 0; i < images.length; i++) addImage(m, images[i], body);
  }

  function dayBreakRow(m) {
    var d = document.createElement('div');
    d.className = 'daybreak';
    var s = document.createElement('span');
    s.textContent = fmtDay(m.at);
    d.appendChild(s);
    return d;
  }

  function insertRows(messages, atTop) {
    var frag = document.createDocumentFragment();
    var made = [];
    if (!messages) return 0;
    for (var i = 0; i < messages.length; i++) {
      var m = messages[i];
      if (!m || m.id == null) continue;
      if (m.dayBreak) frag.appendChild(dayBreakRow(m));
      var el = renderRow(m);
      var id = String(m.id);
      state.rows[id] = el;
      state.raw[id] = m;
      made.push(el);
      frag.appendChild(el);
    }
    if (!made.length) return 0;
    if (atTop) {
      sc.insertBefore(frag, topEl.nextSibling);
      state.rowList = made.concat(state.rowList);
    } else {
      sc.appendChild(frag);
      state.rowList = state.rowList.concat(made);
    }
    // Geometry is only real once the rows are in the document.
    for (var j = 0; j < made.length; j++) measureImages(made[j]);
    return made.length;
  }

  function clearRows() {
    var nodes = sc.querySelectorAll('.msg, .daybreak');
    for (var i = nodes.length - 1; i >= 0; i--) nodes[i].remove();
    state.rows = Object.create(null);
    state.raw = Object.create(null);
    state.rowList = [];
    state.anchor = null;
  }

  // -- anchor arithmetic (§3.2 / §3.6) ------------------------------------

  // The first row whose bottom is past the top edge of the viewport.
  function findAnchor() {
    var rows = state.rowList;
    var top = sc.scrollTop;
    var lo = 0, hi = rows.length - 1, ans = null;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      var r = rows[mid];
      if (r.offsetTop + r.offsetHeight > top) {
        ans = r;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    return ans;
  }

  function capture() {
    var el = findAnchor();
    return el ? { el: el, off: el.offsetTop - sc.scrollTop } : null;
  }

  function restore(cap) {
    if (!cap || !cap.el || !cap.el.isConnected) return false;
    sc.scrollTop = cap.el.offsetTop - cap.off;
    return true;
  }

  function updateAnchor() {
    var el = findAnchor();
    state.anchor = el ? { el: el, delta: el.offsetTop - sc.scrollTop } : null;
  }

  function isAtBottom() {
    return sc.scrollHeight - sc.scrollTop - sc.clientHeight < FOLLOW_SLOP;
  }

  // -- the reader's place -------------------------------------------------

  // Tell the host where the reader is (`chat.reading`). The host keeps the
  // last one and remembers it when the group is left; **the page stores
  // nothing** -- its document may be a located window around a search hit,
  // not the conversation the place is about.
  function reportReading(force) {
    if (!state.resetDone) return;
    var now = Date.now();
    if (!force && state.readingAt && now - state.readingAt < READING_EVERY_MS) {
      // Trailing edge: the last place of a scroll is the one worth keeping.
      if (!state.readingTimer) {
        state.readingTimer = setTimeout(function () {
          state.readingTimer = 0;
          reportReading(true);
        }, READING_EVERY_MS);
      }
      return;
    }
    clearTimeout(state.readingTimer);
    state.readingTimer = 0;
    state.readingAt = now;
    var el = findAnchor();
    hostPost('chat.reading', {
      anchor: el ? String(el.dataset.id) : null,
      offset: el ? el.offsetTop - sc.scrollTop : 0,
      following: isAtBottom()
    });
  }

  // Put the document back where the reader left it (`page.reset.reading`).
  // Returns null when it did, or `{why, want, got}` when it could not.
  // **The host logs the reason**; falling to the bottom without a word is
  // the one answer a reader cannot later explain ("why am I at the bottom
  // again?").
  function restoreReading(reading) {
    if (!reading || reading.id == null) return { why: 'row-missing' };
    var el = state.rows[String(reading.id)];
    if (!el) return { why: 'row-missing' };
    var off = Number(reading.offset);
    if (!isFinite(off)) off = 0;
    var max = Math.max(0, sc.scrollHeight - sc.clientHeight);
    var want = el.offsetTop - off;
    var at = Math.min(max, Math.max(0, want));
    sc.scrollTop = at;
    // The offset is CSS pixels and a late image changes row heights. The
    // row the reader was on must still be the one at the viewport's top;
    // anything else is a place they never were, so the caller goes to the
    // bottom and says why.
    if (findAnchor() !== el) {
      return {
        why: Math.abs(at - want) > 0.5 ? 'clamp-miss' : 'not-anchor',
        want: want,
        got: at
      };
    }
    return null;
  }

  // The reader's follow state, read **now**: a locate or a search step moves
  // the document itself, and waiting for the next scroll frame left
  // `follow` true on a window shorter than the viewport -- so "back to
  // latest" never appeared. Called by those two; ordinary scrolling still
  // goes through `onScroll`.
  function syncFollow() {
    var near = isAtBottom();
    state.follow = near;
    if (near) {
      state.pending = 0;
      hideJump();
    } else {
      showJump();
    }
    reportFollow(false);
    reportReading(false);
  }

  // -- scrolling ----------------------------------------------------------

  function jumpToLatest() {
    // **The host may be holding a located window** (an around page around a
    // search hit), and its end is not the conversation's newest. The local
    // scroll can only reach the end of what is loaded, so the request also
    // goes to the host, which rebuilds at the newest (`feed.returnToLatest`).
    // A live window needs nothing; the scroll below is the whole answer.
    hostPost('chat.jumpLatest');
    state.follow = true;
    state.pending = 0;
    hideJump();
    sc.scrollTop = sc.scrollHeight;
    updateAnchor();
    reportFollow(false);
    reportReading(true);
  }

  var scrollQueued = false;

  function onScrollFrame() {
    if (scrollQueued) return;
    scrollQueued = true;
    (window.requestAnimationFrame || function (f) { setTimeout(f, 16); })(function () {
      scrollQueued = false;
      onScroll();
    });
  }

  function onScroll() {
    var near = isAtBottom();
    if (near) {
      state.pending = 0;
      hideJump();
    } else {
      // **Leaving the bottom is enough to raise it** (the person's
      // 2026-11-09 reading: "滚上去后没看见「↓ 跳到最新」"). It used to be
      // raised only when a message arrived while away, so a reader who
      // scrolled up in a quiet group had no way back except the wheel.
      // `showJump` draws the count only when there is one (`pending > 0`).
      showJump();
    }
    state.follow = near;
    updateAnchor();
    refreshEnd();
    reportFollow(false);
    reportReading(false);
    maybeLoadOlder();
  }

  function reportFollow(force) {
    var sig = (state.follow ? '1' : '0') + ':' + state.pending;
    if (!force && sig === state.lastReport) return;
    state.lastReport = sig;
    hostPost('chat.follow', { follow: state.follow, pending: state.pending });
  }

  function maybeLoadOlder() {
    if (!state.resetDone || state.loading || !state.hasEarlier) return;
    if (sc.scrollTop >= LOAD_OLDER_AT) return;
    askOlder();
  }

  function askOlder() {
    state.loading = true;
    showTop(state.L.loadingOlder);
    var first = state.rowList.length ? state.rowList[0] : null;
    var raw = first ? state.raw[first.dataset.id] : null;
    var before = (raw && raw.seq != null) ? raw.seq : null;
    hostPost('chat.loadOlder', { before: before });

    // A host that never answers must not wedge loading forever. **The pill
    // says the host is slow, not broken**: the wait expiring is not a verdict
    // on it (`chat.loadOlder` may still land late, and the manual retry asks
    // again). Task 3098.
    clearTimeout(state.loadTimer);
    state.loadTimer = setTimeout(function () {
      if (!state.loading) return;
      state.loading = false;
      showTopError(state.L.stillLoading, 'older');
    }, LOAD_OLDER_TIMEOUT_MS);
  }

  function showTop(text) {
    if (text) {
      topText.textContent = text;
      topEl.hidden = false;
    } else {
      topText.textContent = '';
      topEl.hidden = true;
    }
  }

  // A failure the reader can press. It owns the pill until a message that
  // answers it arrives, and the click re-sends the request that failed.
  function showTopError(text, retry) {
    state.topError = { text: text, retry: retry };
    state.loading = false;
    topEl.classList.add('retry');
    showTop(text);
  }

  function clearTopError() {
    if (!state.topError) return;
    state.topError = null;
    topEl.classList.remove('retry');
  }

  // "Start of history" belongs to the very top of the transcript, not to the
  // scrollport: show it only when the reader is actually there. The loading
  // text owns the pill while a request is in flight, and a failure owns it
  // until the host answers.
  function refreshEnd() {
    if (state.loading) return;
    if (state.topError) {
      showTop(state.topError.text);
      return;
    }
    if (!state.hasEarlier && sc.scrollTop < 24) {
      showTop(state.L.endOfHistory);
    } else {
      showTop('');
    }
  }

  function showJump() {
    jumpLabel.textContent = state.L.jumpLatest;
    jumpCount.textContent = state.pending > 0 ? '(' + state.pending + ')' : '';
    jump.hidden = false;
  }

  function hideJump() {
    jump.hidden = true;
    jumpCount.textContent = '';
  }

  // -- the first screen's wait (task 3098) --------------------------------
  //
  // **A page that says `chat.ready` and hears nothing must not spin for
  // ever.** It asks again, with a growing delay, and gives the reader a
  // button. The clock is the page's own: the host may be busy on a big page
  // (a 96 KB one took 104 KB of work on the real machine), so the timeout
  // says "still reading", never "broken". Only the host's own `error` says
  // that.

  var bootEl, bootText, bootRetry;

  function ensureBoot() {
    if (bootEl) return;
    bootEl = document.createElement('div');
    bootEl.id = 'boot';
    bootEl.className = 'boot';
    bootEl.hidden = true;
    bootText = document.createElement('span');
    bootText.className = 'boot-text';
    bootRetry = document.createElement('button');
    bootRetry.type = 'button';
    bootRetry.className = 'boot-retry';
    bootRetry.hidden = true;
    bootRetry.addEventListener('click', retryBoot);
    var box = document.createElement('div');
    box.className = 'boot-box';
    box.appendChild(bootText);
    box.appendChild(bootRetry);
    bootEl.appendChild(box);
    document.body.appendChild(bootEl);
  }

  function armBootTimer() {
    clearTimeout(state.bootTimer);
    state.bootTimer = setTimeout(bootTimedOut, state.bootDelay);
  }

  function startBootWatch() {
    if (state.bootSettled) return;
    ensureBoot();
    bootEl.hidden = false;
    bootEl.classList.remove('failed');
    bootText.textContent = state.L.loadingHistory;
    bootRetry.hidden = true;
    state.bootDelay = BOOT_TIMEOUT_MS;
    armBootTimer();
  }

  function bootTimedOut() {
    if (state.bootSettled) return;
    ensureBoot();
    bootEl.hidden = false;
    bootEl.classList.add('failed');
    bootText.textContent = state.L.stillLoading;
    bootRetry.hidden = false;
    // **The next ask is further away every time** (10, 20, 40, 60 s): a host
    // that is slow, or gone, must not be asked once per ten seconds for the
    // rest of the session.
    state.bootDelay = Math.min(state.bootDelay * 2, BOOT_BACKOFF_MAX_MS);
    if (!state.bootSettled) hostPost('chat.ready', { protocol: PROTOCOL });
    armBootTimer();
  }

  // **Only while there is no good first screen.** Once a `page.reset`
  // without `error` has landed, re-posting `chat.ready` makes the host reset
  // the page again and the reader's place is thrown away -- the host's rule
  // is "every ready gets a reset".
  function retryBoot() {
    if (state.bootSettled) return;
    state.bootDelay = BOOT_TIMEOUT_MS;
    ensureBoot();
    bootEl.hidden = false;
    bootEl.classList.remove('failed');
    bootText.textContent = state.L.loadingHistory;
    bootRetry.hidden = true;
    hostPost('chat.ready', { protocol: PROTOCOL });
    armBootTimer();
  }

  function settleBoot(ok) {
    if (ok) {
      state.bootSettled = true;
      clearTimeout(state.bootTimer);
      state.bootDelay = BOOT_TIMEOUT_MS;
      if (bootEl) {
        bootEl.hidden = true;
        bootEl.classList.remove('failed');
      }
      return;
    }
    // The host answered with a failure: say so, and let the reader ask
    // again. No automatic retry -- a host that said "could not read" is not
    // the same as one that has not answered.
    clearTimeout(state.bootTimer);
    ensureBoot();
    bootEl.hidden = false;
    bootEl.classList.add('failed');
    bootText.textContent = state.L.loadFailed;
    bootRetry.hidden = false;
  }

  // -- host messages ------------------------------------------------------

  function onReset(m) {
    var messages = m.messages || [];
    state.resetDone = false;
    clearRows();
    state.follow = true;
    state.pending = 0;
    state.loading = false;
    clearTimeout(state.loadTimer);
    state.hasEarlier = m.hasEarlier !== false;
    state.hits = [];
    state.hitIndex = -1;

    applyLocale(m.locale);
    applyTheme(m.theme);

    insertRows(messages, true);
    state.resetDone = true;
    // **The first screen is answered, one way or the other** (task 3098).
    // A reset with no `error` settles the boot wait; one that carries an
    // `error` is the host's own word that the read failed, and the retry
    // stays up. Only an `error` reset leaves `bootSettled` false, so a
    // retry re-posts `chat.ready` only while there is no readable screen to
    // lose.
    if (m.error) {
      clearTopError();
      settleBoot(false);
    } else {
      settleBoot(true);
      clearTopError();
    }
    sc.scrollTop = sc.scrollHeight;
    // The host may have a place this group was left at. **A failed restore
    // is said out loud** (`chat.restoreFailed`) and falls to the bottom;
    // the host logs it, because a page's `console` reaches nobody on a real
    // machine and "why am I at the bottom?" needs an answer later.
    if (m.reading) {
      var failed = restoreReading(m.reading);
      if (failed) {
        console.warn('chat: reading restore failed (' + failed.why + '); back to the bottom', m.reading, failed);
        hostPost('chat.restoreFailed', {
          why: failed.why,
          id: m.reading.id == null ? null : String(m.reading.id),
          offset: Number(m.reading.offset) || 0,
          want: Math.round(failed.want || 0),
          got: Math.round(failed.got || 0)
        });
        sc.scrollTop = sc.scrollHeight;
      }
    }
    state.lastW = sc.clientWidth;
    state.lastH = sc.clientHeight;
    updateAnchor();
    state.follow = isAtBottom();
    refreshEnd();
    if (state.follow) hideJump();
    else showJump();
    reportFollow(true);
    reportReading(true);
    // If the first page does not fill the viewport, fill it with older rows.
    // Not after a failed read: the failure is the answer, and asking again
    // immediately is the loop this round exists to remove.
    if (!m.error) maybeLoadOlder();
  }

  function onPrepend(m) {
    var messages = m.messages || [];
    var hadMessage = messages.length > 0;
    state.loading = false;
    clearTimeout(state.loadTimer);

    // The status line is part of the layout: settling it BEFORE the anchor is
    // taken is what keeps the reader's row still (hiding it after the restore
    // shifts everything up by its own height, measured 29px).
    if (m.error) {
      // **A read failure is an answer, not silence** (task 3098). It is not
      // the start of history, so `hasEarlier` stays true and the pill offers
      // the retry rather than "到头了".
      state.hasEarlier = true;
      clearTopError();
      showTopError(state.L.olderFailed, 'older');
    } else {
      state.hasEarlier = hadMessage ? (m.hasEarlier !== false) : false;
      clearTopError();
    }
    refreshEnd();

    var cap = capture();
    var added = insertRows(messages, true);
    if (!m.error && added === 0 && hadMessage) {
      // A page whose messages were all unusable would loop forever; call it
      // the end rather than asking again.
      state.hasEarlier = false;
      refreshEnd();
    }
    if (cap) restore(cap);
    updateAnchor();
    refreshEnd();
    if (!m.error) maybeLoadOlder();
  }

  function onAppend(m) {
    var msg = m.message;
    if (!msg || msg.id == null) return;
    var follow = isAtBottom();
    if (follow) {
      insertRows([msg], false);
      state.follow = true;
      state.pending = 0;
      hideJump();
      sc.scrollTop = sc.scrollHeight;
    } else {
      var cap = capture();
      insertRows([msg], false);
      restore(cap);
      state.follow = false;
      var hostCount = (typeof m.pending === 'number') ? m.pending : 0;
      state.pending = Math.max(state.pending + 1, hostCount);
      showJump();
    }
    updateAnchor();
    reportFollow(false);
  }

  function onUpdate(m) {
    if (m.id == null) return;
    var el = state.rows[String(m.id)];
    if (!el) return;
    var raw = state.raw[String(m.id)] || { id: m.id };
    raw.text = m.text;
    state.raw[String(m.id)] = raw;
    var cap = capture();
    var body = el.querySelector('.body');
    if (body) renderBody(body, raw);
    measureImages(el);
    if (state.follow) sc.scrollTop = sc.scrollHeight;
    else restore(cap);
    updateAnchor();
  }

  function onLocate(m) {
    if (m.id == null) return;
    var el = state.rows[String(m.id)];
    if (!el) return;
    clearMarks('hit');
    if (m.ranges && m.ranges.length) {
      var body = el.querySelector('.body');
      if (body) markRanges(body, m.ranges, 'hit');
    }
    flashRow(el);
    var top = el.offsetTop - Math.min(80, Math.max(24, sc.clientHeight * 0.2));
    sc.scrollTop = Math.max(0, top);
    updateAnchor();
    syncFollow();
  }

  function flashRow(el) {
    el.classList.add('locate');
    setTimeout(function () { el.classList.remove('locate'); }, 1600);
  }

  function onSearch(m) {
    clearMarks('hit');
    var hits = m.hits || [];
    var query = String(m.query || '');
    state.hits = [];
    state.hitIndex = -1;
    for (var i = 0; i < hits.length; i++) {
      var hit = hits[i];
      if (!hit || hit.id == null) continue;
      state.hits.push(String(hit.id));
      var el = state.rows[String(hit.id)];
      if (!el) continue;
      var body = el.querySelector('.body');
      if (!body) continue;
      if (hit.ranges && hit.ranges.length) markRanges(body, hit.ranges, 'hit');
      else if (query) markLiteral(body, query, 'hit');
    }
  }

  // Optional helper for a host that wants the page to drive next/previous.
  // The normal path is the host sending page.locate for the hit it chose.
  function searchStep(delta) {
    if (!state.hits.length) return null;
    state.hitIndex = (state.hitIndex + (delta || 1) + state.hits.length) % state.hits.length;
    var id = state.hits[state.hitIndex];
    var el = state.rows[id];
    if (el) {
      flashRow(el);
      sc.scrollTop = Math.max(0, el.offsetTop - Math.min(80, Math.max(24, sc.clientHeight * 0.2)));
      updateAnchor();
      syncFollow();
    }
    return id;
  }

  function onImage(m) {
    if (!m || !m.src) return;
    var cap = capture();
    var imgs = sc.querySelectorAll('img');
    var hit = false;
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var src = img.dataset.src || img.getAttribute('src') || '';
      if (src === m.src || img.getAttribute('src') === m.src) {
        hit = true;
        if (m.url) img.src = m.url;
        if (m.width && m.height) {
          img.width = m.width;
          img.height = m.height;
          img.style.aspectRatio = m.width + ' / ' + m.height;
        } else if (m.width) {
          img.width = m.width;
        }
        img.classList.remove('pending');
        // The reserved box is what the later load event will measure against.
        img.dataset.gh = String(img.offsetHeight);
      }
    }

    // A bare path the host could read: the placeholder becomes the image.
    // It was the whole text node, so it is a block-level picture.
    var paths = sc.querySelectorAll('.pathref[data-path-src]');
    for (var p = 0; p < paths.length; p++) {
      var span = paths[p];
      if (span.dataset.pathSrc !== String(m.src)) continue;
      hit = true;
      var made = document.createElement('img');
      made.alt = span.textContent;
      made.dataset.src = String(m.src);
      if (m.url) made.src = m.url;
      if (m.width && m.height) {
        made.width = m.width;
        made.height = m.height;
        made.style.aspectRatio = m.width + ' / ' + m.height;
      } else if (m.width) {
        made.width = m.width;
      }
      span.parentNode.replaceChild(made, span);
      made.dataset.gh = String(made.offsetHeight);
    }

    if (!hit) return;
    if (state.follow) sc.scrollTop = sc.scrollHeight;
    else restore(cap);
    updateAnchor();
  }

  // -- theme / locale -----------------------------------------------------

  function cssVarName(key) {
    if (key.indexOf('--') === 0) return key;
    return '--' + key.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase();
  }

  function applyTheme(t) {
    if (!t || typeof t !== 'object') return;
    var cap = state.resetDone ? capture() : null;
    var root = document.documentElement;

    // A new theme replaces the previous injection wholesale, so a partial
    // theme falls back to the built-in palette instead of inheriting stale
    // values from the one before it.
    for (var v = 0; v < state.themeVars.length; v++) {
      root.style.removeProperty(state.themeVars[v]);
    }
    state.themeVars = [];

    if (t.mode === 'light' || t.mode === 'dark') {
      root.setAttribute('data-theme', t.mode);
    }
    for (var k in t) {
      if (!Object.prototype.hasOwnProperty.call(t, k)) continue;
      if (k === 'mode') continue;
      var name = cssVarName(k);
      var value = t[k];
      if (value == null) continue;
      root.style.setProperty(name, String(value));
      state.themeVars.push(name);
    }

    if (state.resetDone) {
      // Setting a variable may have changed the type size; read layout now.
      if (state.follow) sc.scrollTop = sc.scrollHeight;
      else restore(cap);
      updateAnchor();
    }
  }

  function applyLocale(locale) {
    var lang = String(locale || 'zh').toLowerCase().indexOf('en') === 0 ? 'en' : 'zh';
    state.locale = locale || lang;
    state.L = STRINGS[lang];
    document.documentElement.lang = locale || lang;
    jumpLabel.textContent = state.L.jumpLatest;
    var buttons = sc ? sc.querySelectorAll('.copy') : [];
    for (var i = 0; i < buttons.length; i++) buttons[i].textContent = state.L.copy;
  }

  // -- search marking -----------------------------------------------------

  function escapeRegExp(s) {
    return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function textNodesOf(root, cls) {
    var out = [];
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var n;
    while ((n = walker.nextNode())) {
      var p = n.parentElement;
      if (p && p.closest && p.closest('mark.' + cls)) continue;
      out.push(n);
    }
    return out;
  }

  // Wrap [a, b) of one text node in <mark class=cls>. Splitting from the end
  // of a node keeps earlier offsets valid while we walk ranges backwards.
  function wrapSegment(node, a, b, cls) {
    if (!node.nodeValue || b <= a) return;
    var target = node;
    if (a > 0) target = target.splitText(a);
    target.splitText(b - a);
    var mark = document.createElement('mark');
    mark.className = cls;
    target.parentNode.insertBefore(mark, target);
    mark.appendChild(target);
  }

  function normRange(r) {
    if (!r) return null;
    var start, end;
    if (Array.isArray(r)) { start = r[0]; end = r[1]; }
    else { start = r.start; end = r.end; }
    start = Number(start);
    end = Number(end);
    if (!isFinite(start) || !isFinite(end) || end <= start) return null;
    return { start: Math.max(0, start), end: Math.max(0, end) };
  }

  // Offsets are into the body's text content (the visible characters), end
  // exclusive. Ranges may be [start, end] or {start, end}.
  function markRanges(root, ranges, cls) {
    var segs = [];
    var nodes = textNodesOf(root, cls);
    var pos = 0;
    for (var i = 0; i < nodes.length; i++) {
      var len = nodes[i].nodeValue.length;
      segs.push({ node: nodes[i], start: pos, end: pos + len });
      pos += len;
    }
    var norm = [];
    for (var r = 0; r < ranges.length; r++) {
      var nr = normRange(ranges[r]);
      if (nr && nr.start < pos) norm.push(nr);
    }
    norm.sort(function (a, b) { return b.start - a.start; });

    for (var n = 0; n < norm.length; n++) {
      var range = norm[n];
      for (var s = segs.length - 1; s >= 0; s--) {
        var seg = segs[s];
        if (seg.end <= range.start) break;
        if (seg.start >= range.end) continue;
        var a = Math.max(range.start, seg.start) - seg.start;
        var b = Math.min(range.end, seg.end) - seg.start;
        wrapSegment(seg.node, a, b, cls);
      }
    }
  }

  function markLiteral(root, query, cls) {
    if (!query) return;
    var re = new RegExp(escapeRegExp(query), 'gi');
    var nodes = textNodesOf(root, cls);
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      re.lastIndex = 0;
      var matches = [];
      var m;
      while ((m = re.exec(node.nodeValue))) {
        matches.push([m.index, m.index + m[0].length]);
        if (!m[0].length) re.lastIndex++;
      }
      for (var j = matches.length - 1; j >= 0; j--) {
        wrapSegment(node, matches[j][0], matches[j][1], cls);
      }
    }
  }

  function clearMarks(cls) {
    var marks = sc.querySelectorAll('mark.' + cls);
    for (var i = marks.length - 1; i >= 0; i--) {
      var mark = marks[i];
      var text = document.createTextNode(mark.textContent);
      mark.parentNode.replaceChild(text, mark);
    }
    var bodies = sc.querySelectorAll('.body');
    for (var b = 0; b < bodies.length; b++) bodies[b].normalize();
  }

  // -- events -------------------------------------------------------------

  function onClick(ev) {
    var t = ev.target;
    if (!t || !t.closest) return;
    var a = t.closest('a[href]');
    if (a && sc.contains(a)) {
      ev.preventDefault();
      hostPost('chat.openLink', { href: a.getAttribute('href') });
      return;
    }
    // **A clicked image is the host's to open** (design §四). The page sends
    // the image's *original* source (`dataset.src`, not the `data:` ticket it
    // may be showing) as its own message, `chat.openImage`, and the host
    // decides from the file's own header whether it is a picture, then hands
    // it to the system's default program. Nothing here mints a ticket or asks
    // for the side-panel preview: that route is judged against the chat's
    // workdir and refuses a picture kept outside it (`/tmp`), which is why
    // clicking one used to end in a preview that could not read the path.
    // `data:` / `blob:` / `polter-file:` are not places to open, and a
    // non-image path keeps its own route (`filelink`).
    var img = t.closest('img');
    if (img && sc.contains(img)) {
      ev.preventDefault();
      var src = img.dataset.src || img.getAttribute('src') || '';
      if (src && !/^(data:|blob:|polter-file:)/i.test(src)) {
        hostPost('chat.openImage', { src: src });
      }
    }
  }

  function onContextMenu(ev) {
    var t = ev.target;
    var row = t && t.closest ? t.closest('.msg') : null;
    if (!row || !sc.contains(row)) return;
    ev.preventDefault();
    hostPost('chat.menu', {
      id: row.dataset.id,
      x: Math.round(ev.clientX),
      y: Math.round(ev.clientY)
    });
  }

  function onCopy() {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed) return;
    var text = sel.toString();
    if (text) hostPost('chat.copy', { text: text });
    // Default copy is deliberately not prevented: the selection still
    // reaches the system clipboard even if no host is listening.
  }

  function onResize() {
    var w = sc.clientWidth;
    var h = sc.clientHeight;
    if (!state.resetDone) {
      state.lastW = w;
      state.lastH = h;
      return;
    }
    var widthChanged = w !== state.lastW;
    state.lastW = w;
    state.lastH = h;
    if (!widthChanged) return;

    // ResizeObserver runs after the container has its new size, but the rows
    // may still be laid out at the old width (measured: anchorTop was still
    // the pre-resize offset here). Restore now for the common case and again
    // on the next frame, once the reflow has actually landed. The anchor is
    // captured up front because the provisional scroll can overwrite it.
    var wasFollowing = state.follow;
    var cap = state.anchor && state.anchor.el
      ? { el: state.anchor.el, off: state.anchor.delta }
      : null;
    function settle() {
      if (wasFollowing) {
        sc.scrollTop = sc.scrollHeight;
      } else if (cap && cap.el.isConnected) {
        sc.scrollTop = cap.el.offsetTop - cap.off;
      }
      updateAnchor();
    }
    settle();
    if (window.requestAnimationFrame) {
      window.requestAnimationFrame(function () {
        settle();
        if (!wasFollowing) reportFollow(false);
      });
    } else {
      reportFollow(false);
    }
  }

  // -- lifecycle ----------------------------------------------------------

  function init() {
    sc = document.getElementById('scroll');
    topEl = document.getElementById('top');
    topText = document.getElementById('top-text');
    jump = document.getElementById('jump');
    jumpLabel = document.getElementById('jump-label');
    jumpCount = document.getElementById('jump-count');
    if (!sc || !jump) return;

    jumpLabel.textContent = state.L.jumpLatest;
    jump.addEventListener('click', function (ev) {
      ev.preventDefault();
      jumpToLatest();
    });
    sc.addEventListener('scroll', onScrollFrame, { passive: true });
    sc.addEventListener('click', onClick);
    sc.addEventListener('contextmenu', onContextMenu);
    document.addEventListener('copy', onCopy);
    // The pill's retry (task 3098): only while it is a failure, and it asks
    // for exactly the request that failed.
    topEl.addEventListener('click', function () {
      if (!state.topError) return;
      var retry = state.topError.retry;
      clearTopError();
      state.loading = false;
      refreshEnd();
      if (retry === 'boot') retryBoot();
      else askOlder();
    });

    if (window.ResizeObserver) {
      var ro = new ResizeObserver(function () { onResize(); });
      ro.observe(sc);
    } else {
      window.addEventListener('resize', onResize);
    }

    // **The last word is not lost to the throttle.** A tab hidden or a page
    // going away during the trailing window would otherwise leave the host
    // with a place up to 200 ms stale; both are moments where the reader's
    // next action is "come back to this".
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') reportReading(true);
    });
    window.addEventListener('pagehide', function () { reportReading(true); });

    // **The wait starts now, not when the host answers.** A `page.reset`
    // that never comes is the dead "Loading chat history…" this round is
    // for (task 3098); the timer is disarmed by the first reset without an
    // `error`.
    startBootWatch();
    hostPost('chat.ready', { protocol: PROTOCOL });
  }

  window.polterChat = {
    protocol: PROTOCOL,
    receive: receive,
    sent: [],
    state: state,
    jumpToLatest: jumpToLatest,
    searchStep: searchStep,
    relayout: onResize
  };

  window.addEventListener('message', function (ev) {
    if (ev.source === window) receive(ev.data);
  });
  if (window.chrome && window.chrome.webview && window.chrome.webview.addEventListener) {
    window.chrome.webview.addEventListener('message', function (ev) {
      receive(ev.data);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

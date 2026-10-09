/* ============================================================================
   SafeOut UI v3 — 设计稿运行时（仅设计稿使用，不进产品）
   职责：① 图标内联注入（零网络依赖，file:// 直接打开也能看）
        ② 明暗 / 强调色切换
   ----------------------------------------------------------------------------
   ⚠️ 本源文件是 `Design/ui/v2/assets/ds.js` 的**副本**（2026-09-30）。
   纪律：新版本从老版本「复制 → 修改」，老版本一字不动 ⇒ 可逐行 diff、可回流。
   当前与 v2 **逐字节相同**，仅本抬头改了 v2 → v3。
   语言包 `i18n.js` **不在 v3 复制**（它是 `Tools/build_i18n.py` 的生成物，
   生成器路径写死 v2 ⇒ 复制品必然静默过期），v3 稿**只读引用** v2 那一份。
   资源处置表见 `../DESIGN-SPEC.md` §12。
   ========================================================================== */
(function () {
  'use strict';

  var I = {
    eject:
      '<path d="M12 4.3 5.3 14.5h13.4z" fill="currentColor" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/>' +
      '<path d="M5.8 18.2h12.4"/>',
    drive:
      '<rect x="2.4" y="6.2" width="19.2" height="11.6" rx="2.6"/>' +
      '<path d="M2.4 14.2h19.2"/>' +
      '<circle cx="7.2" cy="10.2" r="1.1" fill="currentColor" stroke="none"/>' +
      '<circle cx="11" cy="10.2" r="1.1" fill="currentColor" stroke="none"/>',
    driveExt:
      '<rect x="2.4" y="6.2" width="19.2" height="11.6" rx="2.6"/>' +
      '<path d="M2.4 14.2h19.2"/>' +
      '<circle cx="7.2" cy="10.2" r="1.1" fill="currentColor" stroke="none"/>' +
      '<path d="M11.4 17.4h5"/>',
    refresh:
      '<path d="M20.6 12a8.6 8.6 0 1 1-2.52-6.08"/><path d="M20.6 3.6v5.2h-5.2"/>',
    gear:
      '<circle cx="12" cy="12" r="3.1"/>' +
      '<path d="M19.1 14.6a1.6 1.6 0 0 0 .32 1.76l.06.06a1.94 1.94 0 1 1-2.74 2.74l-.06-.06a1.6 1.6 0 0 0-1.76-.32 1.6 1.6 0 0 0-.97 1.46v.17a1.94 1.94 0 1 1-3.88 0v-.09a1.6 1.6 0 0 0-1.05-1.46 1.6 1.6 0 0 0-1.76.32l-.06.06a1.94 1.94 0 1 1-2.74-2.74l.06-.06a1.6 1.6 0 0 0 .32-1.76 1.6 1.6 0 0 0-1.46-.97h-.17a1.94 1.94 0 1 1 0-3.88h.09a1.6 1.6 0 0 0 1.46-1.05 1.6 1.6 0 0 0-.32-1.76l-.06-.06a1.94 1.94 0 1 1 2.74-2.74l.06.06a1.6 1.6 0 0 0 1.76.32h.08a1.6 1.6 0 0 0 .97-1.46v-.17a1.94 1.94 0 1 1 3.88 0v.09a1.6 1.6 0 0 0 .97 1.46 1.6 1.6 0 0 0 1.76-.32l.06-.06a1.94 1.94 0 1 1 2.74 2.74l-.06.06a1.6 1.6 0 0 0-.32 1.76v.08a1.6 1.6 0 0 0 1.46.97h.17a1.94 1.94 0 1 1 0 3.88h-.09a1.6 1.6 0 0 0-1.46.97z"/>',
    window:
      '<rect x="2.8" y="4.2" width="18.4" height="15.6" rx="2.8"/><path d="M2.8 9.2h18.4"/>' +
      '<circle cx="6.2" cy="6.7" r=".85" fill="currentColor" stroke="none"/>',
    power: '<path d="M12 3.4v8.2"/><path d="M18.5 6.7a9 9 0 1 1-13 0"/>',
    check: '<path d="M4.8 12.6 9.6 17.4 19.2 6.9"/>',
    checkCircle: '<circle cx="12" cy="12" r="8.8"/><path d="m8.4 12.4 2.6 2.6 4.6-5.2"/>',
    warn:
      '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>' +
      '<path d="M12 9v4.2"/><path d="M12 17.1h.01"/>',
    lock:
      '<rect x="4.2" y="10.4" width="15.6" height="10.2" rx="2.6"/>' +
      '<path d="M8.2 10.4V7.2a3.8 3.8 0 0 1 7.6 0v3.2"/>',
    info: '<circle cx="12" cy="12" r="8.8"/><path d="M12 11.2v5"/><path d="M12 7.9h.01"/>',
    x: '<path d="M6.4 6.4 17.6 17.6"/><path d="M17.6 6.4 6.4 17.6"/>',
    chevronDown: '<path d="m6.4 9.4 5.6 5.6 5.6-5.6"/>',
    chevronRight: '<path d="m9.4 6.4 5.6 5.6-5.6 5.6"/>',
    externalLink:
      '<path d="M14.4 4h5.6v5.6"/><path d="M20 4 11.2 12.8"/>' +
      '<path d="M18 14.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4.6"/>',
    shield:
      '<path d="M12 21.6s7.8-3.9 7.8-9.8V5.4L12 2.4 4.2 5.4v6.4c0 5.9 7.8 9.8 7.8 9.8z"/>' +
      '<path d="m8.8 11.8 2.2 2.2 4.2-4.6"/>',
    folder:
      '<path d="M3 7.6A2.6 2.6 0 0 1 5.6 5h2.9l2.1 2.6h8.4A2.6 2.6 0 0 1 21 10.2v7.2A2.6 2.6 0 0 1 18.4 20H5.6A2.6 2.6 0 0 1 3 17.4z"/>',
    photo:
      '<rect x="3" y="4.6" width="18" height="14.8" rx="2.6"/><circle cx="8.6" cy="10" r="1.8"/>' +
      '<path d="m4 17.6 5.2-5 4.4 4.4L16.4 14l4 3.8"/>',
    music:
      '<path d="M9.2 17.8V6.2L19 4.2v11.6"/><circle cx="6.6" cy="18" r="2.6"/><circle cx="16.4" cy="16" r="2.6"/>',
    terminal:
      '<rect x="3" y="4.6" width="18" height="14.8" rx="2.6"/><path d="m7.2 9.4 2.8 2.8-2.8 2.8"/><path d="M13 15h4"/>',
    code: '<path d="m8.4 6.4-5.4 5.6 5.4 5.6"/><path d="m15.6 6.4 5.4 5.6-5.4 5.6"/>',
    cloud:
      '<path d="M17.4 19a4.6 4.6 0 0 0 .4-9.2 6.2 6.2 0 0 0-11.9 1.5A4.2 4.2 0 0 0 7 19z"/>',
    doc:
      '<path d="M14 3H7.2a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h9.6a2 2 0 0 0 2-2V7.6z"/>' +
      '<path d="M14 3v4.6h4.8"/>',
    clock: '<circle cx="12" cy="12" r="8.8"/><path d="M12 7.4V12l3.2 1.9"/>',
    spinner:
      '<path d="M12 3.2v3.4"/><path d="M12 17.4v3.4"/><path d="M3.2 12h3.4"/><path d="M17.4 12h3.4"/>' +
      '<path d="m5.8 5.8 2.4 2.4"/><path d="m15.8 15.8 2.4 2.4"/><path d="m5.8 18.2 2.4-2.4"/><path d="m15.8 8.2 2.4-2.4"/>',
    eye: '<path d="M2.4 12S6 5.6 12 5.6 21.6 12 21.6 12 18 18.4 12 18.4 2.4 12 2.4 12z"/><circle cx="12" cy="12" r="3"/>',
    down: '<path d="M12 4.4v11"/><path d="m7.2 10.8 4.8 4.8 4.8-4.8"/><path d="M4.4 19.6h15.2"/>',
    sun: '<circle cx="12" cy="12" r="4.2"/><path d="M12 2.4v2.2"/><path d="M12 19.4v2.2"/><path d="M2.4 12h2.2"/><path d="M19.4 12h2.2"/><path d="m5.2 5.2 1.6 1.6"/><path d="m17.2 17.2 1.6 1.6"/><path d="m5.2 18.8 1.6-1.6"/><path d="m17.2 6.8 1.6-1.6"/>',
    moon: '<path d="M20.4 14.2A8.6 8.6 0 0 1 9.8 3.6a8.8 8.8 0 1 0 10.6 10.6z"/>',
    type: '<path d="M4.6 6.6V4.8h14.8v1.8"/><path d="M12 4.8v14.4"/><path d="M9 19.2h6"/>',
    ruler: '<rect x="2.6" y="8.2" width="18.8" height="7.6" rx="1.8"/><path d="M7 8.2v3"/><path d="M11 8.2v4.4"/><path d="M15 8.2v3"/><path d="M19 8.2v4.4"/>',
    layers: '<path d="m12 2.6 9.4 5-9.4 5-9.4-5z"/><path d="m2.6 12.6 9.4 5 9.4-5"/><path d="m2.6 17.4 9.4 5 9.4-5"/>',
    wifi:
      '<path d="M2.4 8.6a14.2 14.2 0 0 1 19.2 0"/><path d="M6 12.4a9.2 9.2 0 0 1 12 0"/>' +
      '<path d="M9.5 16a4.2 4.2 0 0 1 5 0"/>' +
      '<circle cx="12" cy="19.2" r="1" fill="currentColor" stroke="none"/>',
    battery:
      '<rect x="2.2" y="7.6" width="16.6" height="8.8" rx="2.6"/>' +
      '<rect x="4.3" y="9.7" width="10.4" height="4.6" rx="1.2" fill="currentColor" stroke="none"/>' +
      '<path d="M21.2 10.6v2.8"/>',
    search: '<circle cx="10.8" cy="10.8" r="7"/><path d="m16 16 4.6 4.6"/>'
  };

  function build(name) {
    var body = I[name];
    if (!body) return '';
    return (
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' +
      body +
      '</svg>'
    );
  }

  function hydrate(root) {
    var nodes = (root || document).querySelectorAll('[data-i]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.getAttribute('data-i-done')) continue;
      el.innerHTML = build(el.getAttribute('data-i'));
      el.setAttribute('data-i-done', '1');
      if (el.tagName === 'I' || el.tagName === 'SPAN') {
        el.style.display = 'inline-flex';
        el.style.alignItems = 'center';
        el.style.justifyContent = 'center';
      }
    }
  }

  // ---- 明暗切换 ----
  window.dsSetTheme = function (t) {
    document.documentElement.setAttribute('data-theme', t);
    document.querySelectorAll('[data-theme-btn]').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-theme-btn') === t));
    });
  };

  // ---- 强调色切换 ----
  window.dsSetAccent = function (a) {
    document.documentElement.setAttribute('data-accent', a);
  };

  // ==========================================================================
  // 多语言（i18n）
  // --------------------------------------------------------------------------
  // 设计稿的界面文案**不再硬编码在 HTML 里**：HTML 里保留中文作为「源语言快照」，
  // 真正显示的是 `i18n.js` 里当前语言那一套值。这样：
  //   · 加一门语言 = 在 i18n.js 补一套值，页面一个字都不用改；
  //   · 换语言后可以**量测英文下的布局** —— 本地化最容易破的就是固定尺寸容器。
  //
  // 标注方式：
  //   <div data-i18n="showDockIcon">在 Dock 中显示图标</div>
  //   <button data-i18n-attr="aria-label:refresh,title:refresh">…</button>
  //   <button data-i18n-attr="aria-label:ejectDiskFormat" data-i18n-args="WD Blue">…</button>
  // 值里允许 HTML（<b> / <code> / <i data-i="gear">），回填后会重新水合图标。
  //
  // ⚠️ 值里**带占位符**时（`ejectDiskFormat` = `推出 %@`）必须给 `data-i18n-args`，
  // 否则界面上会显示字面量 `%@`（aria-label 会被 VoiceOver 念成「百分号 at」）。
  // 守卫会盯这件事（§8.70.2）。
  // ==========================================================================

  /// 缺键登记表：控制台会报出来，避免「漏翻了却看不出来」。
  var _missing = {};

  /// 取一条文案：当前语言 → 回退简体中文 → 回退键名本身。
  function t(lang, key) {
    var table = (window.DS_L10N || {})[lang] || {};
    var fallback = (window.DS_L10N || {})['zh-Hans'] || {};
    if (table[key] != null) return table[key];
    if (fallback[key] != null) {
      if (!_missing[key]) {
        _missing[key] = 1;
        console.warn('[ds] 语言 ' + lang + ' 缺少文案键：' + key + '（已回退简体中文）');
      }
      return fallback[key];
    }
    console.warn('[ds] 语言包里根本没有这个键：' + key);
    return key;
  }

  /// 取 `data-i18n-args` 里的参数（逗号分隔，按占位符出现的顺序填）。
  function argsOf(el) {
    var raw = el.getAttribute('data-i18n-args');
    return raw ? raw.split(',') : [];
  }

  /// 把值里的 `%@` / `%d` **按顺序**换成参数。
  ///
  /// ⚠️ 参数不够时**保留原占位符**：让它明晃晃地留在界面上，
  /// 而不是悄悄显示成空串 —— 「少给了一个参数」和「界面本来就没这个数字」长得一样。
  function fill(value, args) {
    var i = 0;
    return value.replace(/%[@sd]/g, function (m) {
      return i < args.length ? args[i++] : m;
    });
  }

  /// 把当前语言的文案写回页面。
  ///
  /// **必须重新 hydrate**：`innerHTML` 会把 `<i data-i="gear">` 里已经注入的 `<svg>` 覆盖掉，
  /// 不重新水合的话切到英文后**所有图标消失** —— 而 HTML 里明明有、DOM 里也还在，
  /// 只是变成了空标签（与 §8.34 那个「水合前量测」是同一类问题）。
  function applyLang(lang) {
    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      el.innerHTML = fill(t(lang, el.getAttribute('data-i18n')), argsOf(el));
    });
    document.querySelectorAll('[data-i18n-attr]').forEach(function (el) {
      var args = argsOf(el);
      el.getAttribute('data-i18n-attr').split(',').forEach(function (pair) {
        var parts = pair.split(':');
        if (parts.length !== 2) return;
        // 属性里不能带 HTML 标签，剥掉再写（否则 aria-label 会被 VoiceOver 念成标签名）
        el.setAttribute(parts[0], fill(t(lang, parts[1]), args).replace(/<[^>]+>/g, ''));
      });
    });
    hydrate(document);
  }

  window.dsSetLang = function (lang) {
    document.documentElement.setAttribute('lang', lang);
    document.querySelectorAll('[data-lang-btn]').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-lang-btn') === lang));
    });
    applyLang(lang);
    try { localStorage.setItem('ds-lang', lang); } catch (e) { /* file:// 下可能不可用，忽略 */ }
  };

  /// 生成语言切换栏。**自动插到 .doc__nav 后面，页面 HTML 不用改** ——
  /// 否则 9 个页面各贴一份，漏一个就变成「那页切不了语言」。
  function buildLangBar() {
    var nav = document.querySelector('.doc__nav');
    if (!nav || !window.DS_LANGS || document.querySelector('.langbar')) return;

    var bar = document.createElement('div');
    bar.className = 'langbar';

    var label = document.createElement('span');
    label.className = 'langbar__label';
    label.textContent = t(currentLang(), 'appLanguage');
    bar.appendChild(label);

    window.DS_LANGS.forEach(function (l) {
      var b = document.createElement('button');
      b.className = 'pill';
      b.setAttribute('type', 'button');
      b.setAttribute('data-lang-btn', l.code);
      b.setAttribute('aria-pressed', String(l.code === currentLang()));
      b.textContent = l.name;          // 语言名不翻译，永远用各自语言的写法
      b.addEventListener('click', function () { window.dsSetLang(l.code); });
      bar.appendChild(b);
    });

    var hint = document.createElement('span');
    hint.className = 'langbar__hint';
    hint.textContent = '切换语言后，界面文案一起变；设计说明（中文论述）保持不变。';
    bar.appendChild(hint);

    nav.parentNode.insertBefore(bar, nav.nextSibling);
  }

  /// 当前语言：本地存储 → 浏览器语言 → 简体中文。
  function currentLang() {
    var saved = null;
    try { saved = localStorage.getItem('ds-lang'); } catch (e) { /* 忽略 */ }
    if (saved && (window.DS_L10N || {})[saved]) return saved;
    var nav2 = (navigator.language || 'zh-Hans');
    if ((window.DS_L10N || {})[nav2]) return nav2;
    return 'zh-Hans';
  }

  function init() {
    hydrate(document);

    // 主题按钮
    document.querySelectorAll('[data-theme-btn]').forEach(function (b) {
      b.addEventListener('click', function () {
        window.dsSetTheme(b.getAttribute('data-theme-btn'));
      });
    });

    // 强调色色板
    document.querySelectorAll('[data-accent-btn]').forEach(function (b) {
      b.addEventListener('click', function () {
        var a = b.getAttribute('data-accent-btn');
        window.dsSetAccent(a);
        document.querySelectorAll('[data-accent-btn]').forEach(function (x) {
          x.setAttribute('aria-pressed', String(x === b));
        });
      });
    });

    // 交互演示：开关
    document.querySelectorAll('.switch').forEach(function (s) {
      s.addEventListener('click', function () {
        s.setAttribute('aria-checked', s.getAttribute('aria-checked') === 'true' ? 'false' : 'true');
      });
    });

    // 交互演示：分段控件
    document.querySelectorAll('.seg').forEach(function (seg) {
      seg.querySelectorAll('.seg__opt').forEach(function (o) {
        o.addEventListener('click', function () {
          seg.querySelectorAll('.seg__opt').forEach(function (x) {
            x.setAttribute('aria-selected', String(x === o));
          });
        });
      });
    });

    // 交互演示：行悬停已由 CSS 处理；点击磁盘行切换证据区展开
    document.querySelectorAll('[data-expandable]').forEach(function (row) {
      var evid = row.querySelector('.evid');
      if (!evid) return;
      var collapsed = false;
      var head = row.querySelector('[data-toggle-evid]');
      if (!head) return;
      head.addEventListener('click', function (e) {
        e.preventDefault();
        collapsed = !collapsed;
        evid.style.display = collapsed ? 'none' : '';
        head.setAttribute('aria-expanded', String(!collapsed));
      });
    });

    // ---- 多语言 ----
    // 顺序有讲究：**先建语言栏**（它会读文案），**再应用语言**
    // （applyLang 用 innerHTML 覆盖节点，之后必须重新 hydrate，见 applyLang 的注释）。
    buildLangBar();
    window.dsSetLang(currentLang());
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

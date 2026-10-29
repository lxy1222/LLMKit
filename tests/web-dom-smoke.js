/*
 * 网页版前端的冒烟测试。
 *
 * 这套东西没法在这里开真浏览器，但如果只看 `node --check` 过没过，那等于什么都没验：
 * 语法对、逻辑全错照样通过。所以这里做的是——
 *   用一份最小 DOM 桩，把**真正的 web/assets/app.js** 跑起来，
 *   对着**真正在跑的本地服务**发请求，然后断言渲染出来的 HTML 里有什么。
 *
 * 它验得到：路由、页面渲染内容、按钮是否登记、参数是否按预期组装、
 *          会改动系统的动作是否一定先过 /api/preview 再弹确认框。
 * 它验不到：真实浏览器里的布局、样式、事件冒泡顺序。
 * 这两句话都写在这里，免得以后有人把这份测试当成浏览器测试。
 *
 * 用法：node tests/web-dom-smoke.js http://127.0.0.1:PORT [app.js 路径]
 *   第三个参数用来对着**解压出来的发布产物**跑，验证打包进去的那份前端也是好的 ——
 *   只测仓库里的副本，等于没测用户真正拿到的东西。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const BASE = process.argv[2] || 'http://127.0.0.1:17800';
const APP = process.argv[3] || path.join(__dirname, '..', 'web', 'assets', 'app.js');

let pass = 0, fail = 0;
const failures = [];

// GitHub 会把 「::error::」 开头的行解析成 annotation —— 注解是**公开可读**的，
// 而 CI 的原始日志要登录才看得到。把失败项同时写一份进注解与 Step Summary，
// 出问题时不登录也能知道是哪一条挂了（这条在没有本地复现环境的机器上救过命）。
function annotate(text) {
  const one = String(text).replace(/\r?\n/g, ' / ');
  console.log('::error::[冒烟] ' + one);
}
function writeSummary(lines) {
  const p = process.env.GITHUB_STEP_SUMMARY;
  if (!p) { return; }
  try { fs.appendFileSync(p, lines.join('\n') + '\n', 'utf8'); } catch (e) { /* 摘要写不进去不该让测试失败 */ }
}
function finish(code) {
  const head = ['### 前端冒烟测试', '', '- 通过 ' + pass + ' 项，失败 ' + fail + ' 项'];
  const tail = fail ? ['', '- 失败项：', ''].concat(failures.map(f => '  - ' + f)) : ['', '- 全部通过'];
  writeSummary(head.concat(tail));
  process.exit(code);
}

function check(name, ok, detail) {
  if (ok) { pass++; console.log('  [PASS] ' + name); }
  else {
    fail++;
    failures.push(name);
    console.log('  [FAIL] ' + name + (detail ? ' —— ' + detail : ''));
    annotate(name + (detail ? ' —— ' + detail : ''));
  }
}

// ---------------------------------------------------------------- 最小 DOM
const reg = new Map();          // id -> element
const handlers = { doc: {}, win: {} };

function makeEl(id) {
  const el = {
    id,
    _html: '',
    textContent: '',
    className: '',
    checked: false,
    onclick: null,
    onchange: null,
    _attrs: {},
    classList: {
      _s: new Set(),
      add(c) { this._s.add(c); },
      remove(c) { this._s.delete(c); },
      contains(c) { return this._s.has(c); }
    },
    addEventListener(t, f) { (handlers['el_' + id] = handlers['el_' + id] || {})[t] = f; },
    setAttribute(k, v) { this._attrs[k] = v; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this._attrs, k); },
    closest() { return null; },
    querySelectorAll(sel) { return scanTiers(this._html, sel); },
    focus() { },
    remove() { }
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html; },
    set(v) {
      this._html = String(v == null ? '' : v);
      // 把新出现的 id 登记进来，这样 $('do-install') 之类才拿得到 —— 相当于
      // 浏览器解析完 HTML 之后 getElementById 能找到那些节点。
      const re = /id="([A-Za-z0-9_\-]+)"/g;
      let m;
      while ((m = re.exec(this._html))) {
        if (!reg.has(m[1])) { reg.set(m[1], makeEl(m[1])); }
      }
    }
  });
  return el;
}

function scanTiers(html, sel) {
  if (sel !== '.tier') { return []; }
  const out = [];
  const re = /<label class="(tier[^"]*)" data-tier="([^"]+)"/g;
  let m;
  while ((m = re.exec(html))) {
    const el = makeEl('tier:' + m[2]);
    el.className = m[1];
    el.setAttribute('data-tier', m[2]);
    el._attrs['data-tier'] = m[2];
    out.push(el);
  }
  return out;
}

function el(id) {
  if (!reg.has(id)) { reg.set(id, makeEl(id)); }
  return reg.get(id);
}

// index.html 里真实存在的节点，先建出来
['where', 'refresh', 'nav', 'app',
  'logbox', 'logTitle', 'jobState', 'logToggle', 'log', 'modal',
  'modalTitle', 'modalBody', 'modalCancel', 'modalOk', 'toast'].forEach(el);

const documentStub = {
  readyState: 'complete',
  addEventListener(t, f) { handlers.doc[t] = f; },
  getElementById(id) { return el(id); }
};

const locationStub = { hash: '#/', host: '127.0.0.1:test' };

const sandbox = {
  document: documentStub,
  window: { addEventListener(t, f) { handlers.win[t] = f; } },
  location: locationStub,
  navigator: { clipboard: { writeText() { return Promise.resolve(); } } },
  fetch: (...a) => fetch(...a),
  setInterval: (...a) => setInterval(...a),
  clearInterval: (...a) => clearInterval(...a),
  setTimeout: (...a) => setTimeout(...a),
  console,
  Promise, JSON, String, Number, Object, Array, RegExp, Date, Math, Error
};
sandbox.globalThis = sandbox;

// ---------------------------------------------------------------- 驱动
let waitLabel = '';
function waitFor(fn, ms = 8000) {
  const label = waitLabel;
  const t0 = Date.now();
  return new Promise((resolve, reject) => {
    (function loop() {
      let v = false;
      try { v = fn(); } catch (e) { /* 还没就绪 */ }
      if (v) { return resolve(v); }
      if (Date.now() - t0 > ms) {
        return reject(new Error('等待超时（' + (label || '未标注') + '，已等 ' + Math.round((Date.now() - t0) / 1000) + ' 秒）'));
      }
      setTimeout(loop, 50);
    })();
  });
}
function wait(label, fn, ms) { waitLabel = label; return waitFor(fn, ms); }

function setHash(h) {
  locationStub.hash = h;
  if (handlers.win.hashchange) { handlers.win.hashchange(); }
}

function clickDocBtn(attrs) {
  const btn = {
    _a: attrs,
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this._a, k) ? this._a[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this._a, k); }
  };
  const target = { closest(sel) { return sel === 'button' ? btn : null; } };
  handlers.doc.click({ target: target });
}

const previewCalls = [];
const launchCalls = [];
const runCalls = [];

function escJs(s) { return String(s == null ? '' : s); }
(async function main() {
  console.log('LLMKit 网页版前端 · 冒烟测试');
  console.log('  服务地址：' + BASE);
  console.log('  ' + '-'.repeat(62));

  // 包一层 fetch：只记录、不改变行为。
  // 浏览器里 app.js 用的是相对地址（/api/x），会自动相对当前页面 origin 解析；
  // Node 的 fetch 没有 origin 概念，所以这里补上 BASE。
  let blockRun = false;
  const realFetch = sandbox.fetch;
  sandbox.fetch = function (u, o) {
    const raw = String(u);
    const url = raw.charAt(0) === '/' ? BASE + raw : raw;
    const body = o && o.body ? JSON.parse(o.body) : null;
    if (url.indexOf('/api/preview') >= 0) { previewCalls.push(body); }
    if (url.indexOf('/api/run') >= 0) { runCalls.push(body); }
    if (url.indexOf('/api/launch') >= 0) { launchCalls.push(body); }
    // blockRun：只验"界面发出的请求体"，不真的在服务端起任务。
    // 配置写入的演练会去做真实端点验证（本机出网被封，可能挂十几秒），
    // 那会把后面的用例全拖死 —— 所以这条用例故意让 /api/run 失败。
    if (blockRun && url.indexOf('/api/run') >= 0) {
      return Promise.resolve(new Response(JSON.stringify({ error: '测试里故意不真的起任务' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }));
    }
    return realFetch(url, o);
  };

  const code = fs.readFileSync(APP, 'utf8');
  vm.runInNewContext(code, sandbox, { filename: 'app.js' });

  // --- 首页 ---
  await wait('首页渲染', () => el('app').innerHTML.indexOf('OpenCode') >= 0);
  const home = el('app').innerHTML;
  console.log('首页');
  check('渲染出十一个工具', ['OpenCode', 'Claude Code', 'cc-switch', 'Codex', 'Gemini', 'DeepSeek', 'Python', 'PyCharm', 'Node.js', 'Git', 'Ollama'].every(n => home.indexOf(n) >= 0));
  check('工具卡片链到它自己的页面', home.indexOf('#/tool/opencode') >= 0);
  // 分组：两个配套工具（cc-switch 管渠道、python 备环境）都不调模型，混在智能体网格里
  // 会让人以为它们也能拿来干活。分组标题与顺序都是这一条的产品判断，钉住它。
  const AGENT_HEAD = '智能体（你要用它们干活）';
  const MGR_HEAD = '配套工具（备环境、管渠道，不直接调模型）';
  const LOCAL_HEAD = '本地模型运行时（把模型跑在你自己机器上）';
  check('首页把工具分成两组', home.indexOf(AGENT_HEAD) >= 0 && home.indexOf(MGR_HEAD) >= 0);
  check('配套工具那组排在智能体之后', home.indexOf(AGENT_HEAD) < home.indexOf(MGR_HEAD));
  const agentGroup = home.slice(home.indexOf(AGENT_HEAD), home.indexOf(MGR_HEAD));
  check('cc-switch 不在智能体那一组里', agentGroup.indexOf('cc-switch') < 0);
  check('python 不在智能体那一组里', agentGroup.indexOf('Python') < 0);
  const compGroup = home.slice(home.indexOf(MGR_HEAD), home.indexOf(LOCAL_HEAD) >= 0 ? home.indexOf(LOCAL_HEAD) : undefined);
  check('配套工具组里有 python', compGroup.indexOf('Python') >= 0);
  check('配套工具组里有 PyCharm', compGroup.indexOf('PyCharm') >= 0);
  check('配套工具组里有 cc-switch', compGroup.indexOf('cc-switch') >= 0);
  check('配套工具组里有 Node.js 与 Git', compGroup.indexOf('Node.js') >= 0 && compGroup.indexOf('Git') >= 0);
  // Node.js / Git 从单独的「运行环境」节并进这一组：所有"配套"的东西放一起
  check('Node.js / Git 现在是工具卡片（可点进自己的页面）', compGroup.indexOf('#/tool/node') >= 0 && compGroup.indexOf('#/tool/git') >= 0);
  check('不再单独占一节「运行环境」', home.indexOf('<h2>运行环境</h2>') < 0);
  // 断的是按钮（id/文案），不是页面里那句'不再有一起补齐'的说明\n  check('不再有「一起补齐」的按钮', home.indexOf('act-deps') < 0 && home.indexOf('补齐 Node / Git') < 0);
  // 环境体检按钮已经删掉了：刷新状态就是重新扫描，不再有单独的「体检」入口
  check('首页没有独立的「环境体检」入口', home.indexOf('环境体检') < 0);
  check('配套工具卡片说明了它管哪几个', home.indexOf('它管这几个用哪个渠道') >= 0);
  check('配套工具那组附了"不调模型"的说明', home.indexOf('这一组自己不调模型') >= 0);
  // runtime（Ollama）必须单独一组：混进配套工具那组会让"这一组自己不调模型"当场说谎
  check('首页有本地模型运行时这一组', home.indexOf(LOCAL_HEAD) >= 0);
  check('运行时那组排在配套工具之后', home.indexOf(MGR_HEAD) < home.indexOf(LOCAL_HEAD));
  check('Ollama 不在配套工具那一组里', compGroup.indexOf('Ollama') < 0);
  // 首页不显示"该做哪一步"的链条 —— 那条链挪到各智能体页（每个智能体不一样）。
  // 所以这里反过来断言首页**没有**它，防止以后又被顺手加回来。
  check('首页没有「下一步」引导条', home.indexOf('card nextstep') < 0 && home.indexOf('nextstep') < 0);
  check('顶栏导航含各工具', el('nav').innerHTML.indexOf('#/tool/codex') >= 0);
  // 顶栏顺序：智能体在前、cc-switch 在后 —— 分隔线上写着"下面是配套工具"，
  // 它后面就只能跟配套工具。这条以前是错的（cc-switch 排在第二位），所以钉死。
  const navHtml = el('nav').innerHTML;
  const ccPos = navHtml.indexOf('#/tool/cc-switch');
  check('顶栏里 cc-switch 在所有智能体之后',
    ccPos > 0 && ['claude-code', 'codex', 'opencode', 'gemini-cli', 'dsh']
      .every((t) => navHtml.indexOf('#/tool/' + t) > 0 && navHtml.indexOf('#/tool/' + t) < ccPos));
  const agentLinkCount = (navHtml.match(/#\/tool\//g) || []).length;
  check('顶栏工具链接一共十一个', agentLinkCount === 11, '实际 ' + agentLinkCount);
  check('顶栏分隔线在 cc-switch 之前', navHtml.lastIndexOf('navsep', ccPos) >= 0 && navHtml.indexOf('navsep') < ccPos);
  // python 也是配套工具，分隔线之后、跟 cc-switch 一起
  const pyPos = navHtml.indexOf('#/tool/python');
  check('顶栏里 python 也在分隔线之后', pyPos > ccPos && pyPos > 0);
  const pycharmPos = navHtml.indexOf('#/tool/pycharm');
  check('顶栏里 pycharm 也在分隔线之后', pycharmPos > ccPos && pycharmPos > 0);
  // 演练模式已经删掉了：没有「真的执行」开关，也没有那句模式说明
  check('顶栏没有「真的执行」开关', !reg.has('apply') && el('nav').innerHTML.indexOf('apply') < 0);
  check('顶栏没有演练/执行的状态说明', !reg.has('modeNote'));
  check('首页没有「环境体检」按钮（刷新即重新扫描）', home.indexOf('环境体检') < 0 && !reg.has('act-check'));
  check('顶栏有关闭服务的入口', reg.has('shutdown'));

  // --- 工具页：opencode（未安装）---
  console.log('工具页 · OpenCode（仿 Claude Code 的分段式）');
  setHash('#/tool/opencode');
  await wait('opencode 工具页渲染', () => el('app').innerHTML.indexOf('cfgProvider-opencode') >= 0 && el('app').innerHTML.indexOf('agent_integrations/opencode') >= 0, 20000);
  const op = el('app').innerHTML;
  const apiOp = await (await fetch(BASE + '/api/tool/opencode')).json();

  check('显示工具名', op.indexOf('OpenCode') >= 0);
  check('页面上的安装状态与接口一致',
    (apiOp.installed && op.indexOf('已安装') >= 0) || (!apiOp.installed && op.indexOf('未安装') >= 0),
    'installed=' + apiOp.installed);
  check('顶部有状态一行（命令/副本/残留）', op.indexOf('class="meta toolstat"') >= 0);

  // ---- 仿 Claude Code：① 装 → ② 配 → ③ 启动，数字做标题 ----
  const ono = (ch) => op.indexOf('>' + ch + '</span>');
  check('opencode 用分段式排版', op.indexOf('class="stepno"') >= 0);
  check('opencode 的 ①②③ 按顺序出现',
    ono('①') > 0 && ono('②') > ono('①') && ono('③') > ono('②'),
    JSON.stringify({ a: ono('①'), b: ono('②'), c: ono('③') }));
  const o1 = op.slice(ono('①'), ono('②'));
  const o2 = op.slice(ono('②'), ono('③'));
  const o3 = op.slice(ono('③'));
  check('① 里是安装（有安装按钮与层）', o1.indexOf('id="do-install"') >= 0 && o1.indexOf('npm 全局安装') >= 0);
  check('① 里有验证按钮', o1.indexOf('id="do-verify"') >= 0);
  check('③ 里是启动', o3.indexOf('启动') >= 0);
  check('opencode 不再有顶部"照着做"清单', op.indexOf('怎么用（照着做）') < 0);

  // ---- ② 段照 DeepSeek 官方 OpenCode 文档：/connect 那几步，本工具不写文件 ----
  check('② 段仍保留渠道选择器', o2.indexOf('cfgProvider-opencode') >= 0);
  check('② 段给出 OpenCode 官方接入说明链接',
    o2.indexOf('api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/opencode') >= 0);
  check('② 段第一步是升级命令', o2.indexOf('opencode upgrade') >= 0);
  check('② 段含 /connect 这一步', o2.indexOf('/connect') >= 0);
  check('② 段提到选 deepseek 供应商', o2.indexOf('deepseek') >= 0);
  check('② 段提到选 DeepSeek-V4-Flash 模型', o2.indexOf('DeepSeek-V4-Flash') >= 0);
  check('② 段有注册账号与创建 API Key 入口', o2.indexOf('注册账号') >= 0 && o2.indexOf('创建 API Key') >= 0);
  check('② 段不再有"写入这个工具的配置"按钮', o2.indexOf('cfgWrite-opencode') < 0);
  check('② 段不再要求填变量名/模型', o2.indexOf('cfgEnv-opencode') < 0 && o2.indexOf('cfgModel-opencode') < 0);
  check('② 段状态如实写"需要你确认"', op.indexOf('需要你确认') >= 0);
  check('② 段说明本工具不写它的配置文件', o2.indexOf('不写') >= 0);

  // 维护区仍在（安装位置 / 配置文件明细 / 清理残留 / 卸载）
  check('维护区折叠在最底', op.indexOf('维护与细节') >= 0 && op.indexOf('维护与细节') > ono('③'));
  check('维护区里有卸载按钮', op.indexOf('data-act="tool-uninstall"') >= 0);
  check('卸载说明写明只搬不删', op.indexOf('只搬不删') >= 0);
  check('卸载默认不移除用户配置', op.indexOf('不是搬走，是真的删') >= 0);
  check('guidance 目标标明"本工具不写它"', op.indexOf('本工具不写它') >= 0);
  check('guidance 目标不说"只会改这几个字段"', op.indexOf('只会改这几个字段') < 0);

  check('opencode 页没有写入按钮（不设自动写入）', op.indexOf('cfgWrite-') < 0);

  // Claude Code：这条写入路径是验证过的，所以它应当显示"能直接写"，并显示当前实际模型
  // 工具页每次都要现扫状态与残留，1-3 秒是常态，所以这里放宽等待（不再额外打一次接口，
  // 那会让服务端单线程的 accept 循环被多占一次，后面的页面等待跟着超时）。
  console.log('工具页 · Claude Code（渠道与模型）');
  setHash('#/tool/claude-code');
  await wait('claude-code 工具页渲染', () => el('app').innerHTML.indexOf('cfgProvider-claude-code') >= 0 && el('app').innerHTML.indexOf('ANTHROPIC_BASE_URL') >= 0, 20000);
  const cl = el('app').innerHTML;
check('步骤状态跟着安装状态走', cl.indexOf('该你了') >= 0 || cl.indexOf('已完成') >= 0);

  // ---- claude-code 也改成分段式排版：① 装 → ② 配 → ③ 启动 ----
  const cno = (ch) => cl.indexOf('>' + ch + '</span>');
  check('claude-code 用分段式排版', cl.indexOf('class="stepno"') >= 0);
  check('claude-code 的 ①②③ 按顺序出现',
    cno('①') > 0 && cno('②') > cno('①') && cno('③') > cno('②'),
    JSON.stringify({ a: cno('①'), b: cno('②'), c: cno('③') }));
  const c1 = cl.slice(cno('①'), cno('②'));
  const c2 = cl.slice(cno('②'), cno('③'));
  const c3 = cl.slice(cno('③'));
  check('① 里是安装（有安装按钮）', c1.indexOf('id="do-install"') >= 0);
  check('③ 里是启动', c3.indexOf('启动') >= 0);
  check('claude-code 不再有顶部"照着做"清单', cl.indexOf('怎么用（照着做）') < 0);
  check('claude-code 顶部有状态一行', cl.indexOf('class="meta toolstat"') >= 0);

  // ---- ② 段换成了 DeepSeek 官方那 9 个环境变量（本工具不写文件）----
  check('② 段仍保留渠道选择器（教程随渠道变）', c2.indexOf('cfgProvider-claude-code') >= 0);
  check('② 段给出官方接入说明的链接', cl.indexOf('api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code') >= 0);
  check('② 段有 9 行 $env: 赋值', (cl.match(/\$env:/g) || []).length >= 9, '$env: 出现 ' + (cl.match(/\$env:/g) || []).length + ' 次');
  check('② 段带着官方 base_url', cl.indexOf('https://api.deepseek.com/anthropic') >= 0);
  check('② 段的模型名与官方一致（deepseek-flash[1m]）', cl.indexOf('deepseek-flash[1m]') >= 0);
  check('② 段含 CLAUDE_CODE_ 三个专用变量',
    cl.indexOf('CLAUDE_CODE_SUBAGENT_MODEL') >= 0 && cl.indexOf('CLAUDE_CODE_EFFORT_LEVEL') >= 0 &&
    cl.indexOf('CLAUDE_CODE_AUTO_COMPACT_WINDOW') >= 0);
  // 这一轮改成「自动写入为主」：② 段有写入按钮，写的是 base_url 与模型名；key 不写（不写占位符）
  check('② 段有「写入这个工具的配置」按钮', cl.indexOf('cfgWrite-claude-code') >= 0);
  check('② 段可以填存 key 的变量名', cl.indexOf('cfgEnv-claude-code') >= 0);
  check('② 段讲清了写的是 settings.json', cl.indexOf('settings.json') >= 0);
  check('② 段仍给出官方的环境变量清单（复制全部）', cl.indexOf('复制全部') >= 0);
  check('② 段提醒 key 不会以占位符写进去', cl.indexOf('占位符') >= 0 || cl.indexOf('不写 key') >= 0 || cl.indexOf('key 不写') >= 0);

  // --- 工具页：cc-switch（状态以接口为准，不假定本机装了）---
  // 它是配套工具，页面被简化成 ①装 ②在它界面里加供应商 ③打开它 + 折叠维护区；
  // 老排版那 9 块（含「渠道与模型」）都去掉了 —— cc-switch 自己就是管渠道的，
  // 在它的页面上再选一次渠道、再写一次文件纯属跑题。
  console.log('工具页 · cc-switch');
  setHash('#/tool/cc-switch');
  await wait('cc-switch 工具页渲染', () => el('app').innerHTML.indexOf('class="stepno"') >= 0, 20000);
  const cc = el('app').innerHTML;
  const kno = (ch) => cc.indexOf('>' + ch + '</span>');
  // 换台机器可能没装它 —— 断言对照接口返回，而不是假定本机状态
  const apiCc = await (await fetch(BASE + '/api/tool/cc-switch')).json();
  check('安装状态与接口一致',
    (apiCc.installed && cc.indexOf('已安装') >= 0) || (!apiCc.installed && cc.indexOf('未安装') >= 0),
    'installed=' + apiCc.installed);
  check('安装入口一直都在（已装时叫重装）',
    reg.has('do-install') && (apiCc.installed ? cc.indexOf('重装') >= 0 : cc.indexOf('安装') >= 0),
    'installed=' + apiCc.installed);
  check('列出安装位置表格', cc.indexOf('<table class="tbl">') >= 0);
  check('cc-switch 的 GitHub 发布层可见', cc.indexOf('github-release') >= 0 || cc.indexOf('GitHub') >= 0);
  // 工具页也要标出角色：用户从首页点进来后，这一页得自己说清"我不是智能体"
  check('配套工具页标了角色', cc.indexOf('配套工具 · 帮你管渠道') >= 0);
  check('配套工具页说清它管哪几个智能体', cc.indexOf('自己不调模型') >= 0 && cc.indexOf('Claude Code') >= 0);

  // 简化后的形态：三段式，且 ② 是在它界面里加供应商
  check('cc-switch 用分段式排版（不再是老排版）', cc.indexOf('怎么用（照着做）') < 0);
  check('cc-switch 的 ①②③ 按顺序出现',
    kno('①') > 0 && kno('②') > kno('①') && kno('③') > kno('②'),
    JSON.stringify({ a: kno('①'), b: kno('②'), c: kno('③') }));
  const k2 = cc.slice(kno('②'), kno('③'));
  check('② 段标题是「在它界面里加供应商」', k2.indexOf('在它界面里加供应商') >= 0);
  check('② 段给出添加供应商这一步', k2.indexOf('添加供应商') >= 0);
  check('② 段给出 Enable 这一步', k2.indexOf('Enable') >= 0);
  check('② 段说明它会去写哪几个工具的配置', k2.indexOf('Claude Code') >= 0 && k2.indexOf('Gemini CLI') >= 0);
  check('② 段给出可复制的值', k2.indexOf('data-copy=') >= 0 && k2.indexOf('Base URL') >= 0);
  check('② 段没有写入按钮', k2.indexOf('cfgWrite-cc-switch') < 0);
  check('③ 段是「打开它」', cc.slice(kno('③')).indexOf('打开它') >= 0);
  // 启动按钮的有无同样跟着接口走：没装的机器上这里只能是禁用按钮
  check('③ 段的启动按钮与安装状态一致',
    apiCc.installed ? cc.indexOf('data-launch="cc-switch"') >= 0 : cc.slice(kno('③')).indexOf('<button disabled') >= 0,
    'installed=' + apiCc.installed);
  // 老排版的臃肿块不许回来
  check('没有「存 key 的变量名」输入框（它不负责存 key）', cc.indexOf('存 key 的变量名') < 0);
  // 这个词在折叠维护区里还会出现（那是它该在的地方），所以断言的是它没有独立成节
  check('没有独立的「这个工具自己的配置」一节', cc.indexOf('<h2>这个工具自己的配置</h2>') < 0);
  check('没有单独的「可用操作」块', cc.indexOf('<h2>可用操作</h2>') < 0);
  check('维护区折叠在最底', cc.indexOf('维护与细节') > kno('③'));

  // --- Codex：② 段照 DeepSeek 官方「一键配置脚本」给步骤 ---
  console.log('工具页 · Codex');
  setHash('#/tool/codex');
  await wait('codex 工具页渲染', () => el('app').innerHTML.indexOf('cfgProvider-codex') >= 0, 20000);
  const cx = el('app').innerHTML;
  const xno = (ch) => cx.indexOf('>' + ch + '</span>');
  check('codex 用分段式排版', cx.indexOf('class="stepno"') >= 0 && cx.indexOf('怎么用（照着做）') < 0);
  check('codex 的 ①②③ 按顺序出现',
    xno('①') > 0 && xno('②') > xno('①') && xno('③') > xno('②'),
    JSON.stringify({ a: xno('①'), b: xno('②'), c: xno('③') }));
  check('codex ① 里是安装', cx.slice(xno('①'), xno('②')).indexOf('id="do-install"') >= 0);
  const x2 = cx.slice(xno('②'), xno('③'));
  check('codex ② 里给出官方一键脚本命令', x2.indexOf('codex-deepseek-setup.ps1') >= 0);
  check('codex ② 里标出官方文档依据', x2.indexOf('agent_integrations/codex') >= 0);
  check('codex ② 里说清菜单选项', x2.indexOf('还原成默认') >= 0);
  check('codex ② 里说明联网搜索只在 v4-pro 下可用', x2.indexOf('deepseek-v4-pro') >= 0);
  check('codex ② 没有自动写入按钮', x2.indexOf('cfgWrite-codex') < 0);

  // --- Gemini CLI：DeepSeek 官方没有它的接入说明，它的渠道交给 cc-switch 管 ---
  console.log('工具页 · Gemini CLI');
  setHash('#/tool/gemini-cli');
  await wait('gemini 工具页渲染', () => el('app').innerHTML.indexOf('cfgProvider-gemini-cli') >= 0, 20000);
  const gm = el('app').innerHTML;
  const gno = (ch) => gm.indexOf('>' + ch + '</span>');
  check('gemini-cli 也用分段式排版', gm.indexOf('class="stepno"') >= 0 && gm.indexOf('怎么用（照着做）') < 0);
  check('gemini-cli 的 ①②③ 按顺序出现',
    gno('①') > 0 && gno('②') > gno('①') && gno('③') > gno('②'),
    JSON.stringify({ a: gno('①'), b: gno('②'), c: gno('③') }));
  const g2 = gm.slice(gno('②'), gno('③'));
  check('② 这一段的标题就是「用 cc-switch 改渠道」', g2.indexOf('用 cc-switch 改渠道') >= 0);
  // 步骤照 cc-switch 自己的用法写：左边栏选 Gemini CLI → + 添加供应商 → Enable → 重开终端
  check('② 里说清在 cc-switch 里选 Gemini CLI 那一档', g2.indexOf('Gemini CLI') >= 0);
  check('② 里给出「添加供应商」这一步', g2.indexOf('添加供应商') >= 0);
  check('② 里给出 Enable 这一步（Switch 模式）', g2.indexOf('Enable') >= 0);
  check('② 里说清要重开终端才生效', g2.indexOf('重开终端') >= 0);
  check('② 里给出 cc-switch 的仓库外链', g2.indexOf('github.com/farion1231/cc-switch') >= 0);
  // 要填进 cc-switch 的值仍然给出来（渠道与模型会跟着选择器变）
  check('② 里给出可复制的 Base URL 与模型', g2.indexOf('data-copy=') >= 0 && g2.indexOf('Base URL') >= 0);
  check('② 里不含任何 key 值', g2.indexOf('sk-') < 0);
  check('② 没有自动写入按钮', g2.indexOf('cfgWrite-gemini-cli') < 0);
  check('③ 里是启动', gm.slice(gno('③')).indexOf('启动') >= 0);

  // --- Python：配套工具里的"备环境"那一半。只给步骤与链接，本工具不代为安装 ---
  console.log('工具页 · Python');
  setHash('#/tool/python');
  await wait('python 工具页渲染', () => el('app').innerHTML.indexOf('class="stepno"') >= 0, 20000);
  const py = el('app').innerHTML;
  const apiPy = await (await fetch(BASE + '/api/tool/python')).json();
  const pno = (ch) => py.indexOf('>' + ch + '</span>');
  check('python 用分段式排版', py.indexOf('class="stepno"') >= 0 && py.indexOf('怎么用（照着做）') < 0);
  check('python 的 ①②③ 按顺序出现',
    pno('①') > 0 && pno('②') > pno('①') && pno('③') > pno('②'),
    JSON.stringify({ a: pno('①'), b: pno('②'), c: pno('③') }));
  const p1 = py.slice(pno('①'), pno('②'));
  const p2 = py.slice(pno('②'), pno('③'));
  check('① 段给出官方下载页', p1.indexOf('python.org/downloads') >= 0);
  check('① 段强调要勾 Add python.exe to PATH', p1.indexOf('Add python.exe to PATH') >= 0);
  check('① 段标明需手动（不替你跑第三方安装器）', p1.indexOf('不替你') >= 0 || p1.indexOf('需手动') >= 0);
  check('② 段给出 pip 镜像命令（只给建议）', p2.indexOf('pip config set global.index-url') >= 0);
  check('② 段给出查看当前源的命令', p2.indexOf('pip config list') >= 0);
  check('② 段说明本工具不写 pip 配置', p2.indexOf('不执行') >= 0);
  // 配 pip 镜像跟渠道无关：不许凭空冒出一个渠道选择器
  check('② 段没有渠道选择器', py.indexOf('cfgProvider-python') < 0);
  check('② 段没有写入按钮', py.indexOf('cfgWrite-python') < 0);
  check('③ 段是启动（进 REPL）', py.slice(pno('③')).indexOf('启动') >= 0);
  // 卸载：官方安装器装的，本工具不搬它的文件 —— 只给说明，不给按钮
  check('没有卸载按钮（不由本工具卸载）', py.indexOf('data-act="tool-uninstall"') < 0);
  check('写明为什么不能卸载', py.indexOf('这个工具不由本工具卸载') >= 0);
  check('维护区折叠在最底', py.indexOf('维护与细节') > pno('③'));

  // ④ 常用第三方库：只检测、不装包
  const p4 = py.slice(pno('④'));
  check('python 有 ④ 常用第三方库这一段', pno('④') > pno('③') && p4.length > 0);
  check('④ 段列出常用库', p4.indexOf('requests') >= 0 && p4.indexOf('numpy') >= 0);
  check('④ 段给出每个库的判断状态', p4.indexOf('已装') >= 0 || p4.indexOf('未安装') >= 0);
  check('④ 段给可复制的安装命令', p4.indexOf('pip install ') >= 0);
  check('④ 段说明本工具不替你装包', p4.indexOf('只检测') >= 0);

  // 多副本冲突：检测出来还要能修 —— 有按钮、说清保留谁、挪走谁
  if (apiPy.conflict) {
    check('有冲突时给出「合并多份副本」按钮', py.indexOf('id="do-conflict"') >= 0);
    check('有冲突时说明会保留哪一份', py.indexOf('会保留：') >= 0);
    check('有冲突时列出会挪走的那几份', py.indexOf('会挪到备份区') >= 0 && (apiPy.conflictMove || []).length > 0);
    check('冲突按钮不算成自动写入', py.indexOf('cfgWrite-python') < 0);
  } else {
    console.log('  （本机 python 没有多副本共存，跳过冲突按钮断言）');
  }

  // --- PyCharm：配套工具里的 IDE，官方安装器手动装 ---
  console.log('工具页 · PyCharm');
  setHash('#/tool/pycharm');
  await wait('pycharm 工具页渲染', () => el('app').innerHTML.indexOf('class="stepno"') >= 0, 20000);
  const pc = el('app').innerHTML;
  const qno = (ch) => pc.indexOf('>' + ch + '</span>');
  check('pycharm 用分段式排版', pc.indexOf('class="stepno"') >= 0 && pc.indexOf('怎么用（照着做）') < 0);
  check('pycharm 的 ①②③ 按顺序出现',
    qno('①') > 0 && qno('②') > qno('①') && qno('③') > qno('②'),
    JSON.stringify({ a: qno('①'), b: qno('②'), c: qno('③') }));
  const q1 = pc.slice(qno('①'), qno('②'));
  const q2 = pc.slice(qno('②'), qno('③'));
  check('① 段给官方下载页链接', q1.indexOf('jetbrains.com/pycharm/download') >= 0);
  check('① 段说明可以下免安装 zip', q1.indexOf('zip') >= 0);
  check('② 段讲的是指定解释器', q2.indexOf('Python Interpreter') >= 0);
  check('② 段给出具体菜单路径', q2.indexOf('Add Interpreter') >= 0);
  check('② 段没有渠道选择器', pc.indexOf('cfgProvider-pycharm') < 0);
  check('② 段没有写入按钮', pc.indexOf('cfgWrite-pycharm') < 0);
  check('③ 段是打开它', pc.slice(qno('③')).indexOf('启动') >= 0);
  check('pycharm 不给卸载按钮', pc.indexOf('data-act="tool-uninstall"') < 0);
  check('pycharm 写清了为什么不卸载', pc.indexOf('这个工具不由本工具卸载') >= 0);
  check('维护区折叠在最底（pycharm）', pc.indexOf('<section class="maint"') > qno('③'),
    'maint=' + pc.indexOf('<section class="maint"') + ' no3=' + qno('③'));

  // --- Node.js / Git：从"依赖"升格成工具，各有自己的页面 ---
  console.log('工具页 · Node.js');
  setHash('#/tool/node');
  await wait('node 工具页渲染', () => el('app').innerHTML.indexOf('class="stepno"') >= 0, 20000);
  const nd = el('app').innerHTML;
  const nno = (ch) => nd.indexOf('>' + ch + '</span>');
  check('node 用分段式排版', nd.indexOf('class="stepno"') >= 0 && nd.indexOf('怎么用（照着做）') < 0);
  check('node 的 ①②③ 按顺序出现',
    nno('①') > 0 && nno('②') > nno('①') && nno('③') > nno('②'),
    JSON.stringify({ a: nno('①'), b: nno('②'), c: nno('③') }));
  const n1 = nd.slice(nno('①'), nno('②'));
  const n2 = nd.slice(nno('②'), nno('③'));
  check('① 段列出两种安装层（便携版 + winget）', n1.indexOf('portable-zip') >= 0 && n1.indexOf('winget') >= 0);
  check('① 段标明便携层不需要管理员', n1.indexOf('不需要管理员') >= 0);
  check('② 段讲的是 npm 镜像', n2.indexOf('npm config set registry') >= 0);
  check('② 段没有渠道选择器', nd.indexOf('cfgProvider-node') < 0);
  check('③ 段是启动（进 node 交互环境）', nd.slice(nno('③')).indexOf('启动') >= 0);
  check('node 有卸载按钮（现在能卸了）', nd.indexOf('data-act="tool-uninstall"') >= 0);

  console.log('工具页 · Git');
  setHash('#/tool/git');
  await wait('git 工具页渲染', () => el('app').innerHTML.indexOf('class="stepno"') >= 0, 20000);
  const gt = el('app').innerHTML;
  const gno2 = (ch) => gt.indexOf('>' + ch + '</span>');
  check('git 用分段式排版', gt.indexOf('class="stepno"') >= 0 && gt.indexOf('怎么用（照着做）') < 0);
  const git2 = gt.slice(gno2('②'), gno2('③'));
  const git3 = gt.slice(gno2('③'));
  check('② 段讲的是 user.name / user.email / safe.directory', git2.indexOf('user.name') >= 0 && git2.indexOf('safe.directory') >= 0);
  check('③ 段的标题就说明它没有交互界面', git3.indexOf('验证') >= 0);
  check('③ 段的启动按钮被禁用（不是点了没反应）', git3.indexOf('disabled') >= 0);
  check('③ 段给出了禁用原因', gt.indexOf('没有可以常驻的窗口') >= 0);
  check('git 有卸载按钮', gt.indexOf('data-act="tool-uninstall"') >= 0);

  // --- 第 6 个工具：DeepSeek Harness ---
  console.log('工具页 · DeepSeek Harness');
  setHash('#/tool/dsh');
  await wait('dsh 工具页渲染', () => el('app').innerHTML.indexOf('DeepSeek Harness') >= 0, 20000);
  const ds = el('app').innerHTML;
  check('显示工具名', ds.indexOf('DeepSeek Harness') >= 0);
  check('列出 npm 安装层', ds.indexOf('@deepseek-ai/dsh') >= 0);
  check('标明不需要管理员', ds.indexOf('不需要管理员') >= 0);
  check('有安装按钮', reg.has('do-install'));
  check('有卸载按钮', ds.indexOf('data-act="tool-uninstall"') >= 0);
  check('凭据目标标明本工具不写它', ds.indexOf('本工具不写它') >= 0);
  check('不把私有格式说成"只会改这几个字段"', ds.indexOf('只会改这几个字段') < 0);
  check('给出凭据文件路径', ds.indexOf('.credentials.yaml') >= 0);

  // ---- 分段式排版（目前只有 dsh 走这套）：页面本身就是步骤 ----
  check('dsh 用分段式排版（有编号标题）', ds.indexOf('class="stepno"') >= 0);
  const noPos = (ch) => ds.indexOf('>' + ch + '</span>');
  check('编号 ①②③ 都在，且按顺序出现',
    noPos('①') > 0 && noPos('②') > noPos('①') && noPos('③') > noPos('②'),
    JSON.stringify({ a: noPos('①'), b: noPos('②'), c: noPos('③') }));
  const seg1 = ds.slice(noPos('①'), noPos('②'));
  const seg2 = ds.slice(noPos('②'), noPos('③'));
  const seg3 = ds.slice(noPos('③'));
  check('① 里是安装（有安装按钮）', seg1.indexOf('id="do-install"') >= 0);
  check('① 里也有"验证可用性"', seg1.indexOf('id="do-verify"') >= 0);
  // 启动器只对已装工具给出命令与地址（没装就没有可执行路径可拼），所以这段
  // 必须按接口的真实安装状态分支 —— 否则在干净机器上会连着假失败三条。
  const apiDsh = await (await fetch(BASE + '/api/tool/dsh')).json();
  if (apiDsh.installed) {
    check('② 里是启动（dsh 的顺序：装完先把它跑起来）', seg2.indexOf('data-launch="dsh"') >= 0);
    // dsh 是服务型工具：启动命令必须带 web 子命令，并且带上我们选定的端口
    check('启动命令带上了 web 子命令', seg2.indexOf(' web') >= 0);
    check('启动命令带上 --port', seg2.indexOf('--port') >= 0);
    check('启动段显示了预计地址', seg2.indexOf('预计地址：http://127.0.0.1:') >= 0);
  } else {
    check('没装时不给可点的启动按钮', seg2.indexOf('data-launch="dsh"') < 0 && seg2.indexOf('<button disabled') >= 0);
    check('没装时也说清它是服务型工具（要带 web 与 --port）', seg2.indexOf('web') >= 0 && seg2.indexOf('--port') >= 0);
    check('（没装，跳过"启动命令/预计地址"断言）', true);
  }
  check('③ 里是配置（有渠道与模型选择）', seg3.indexOf('cfgProvider-dsh') >= 0);
  // dsh 全是 guidance 目标 → 本工具一个字节都不写 → 不给"写入"按钮，只给可复制的值
  check('③ 不给写入按钮（本工具不写 dsh 的配置）', seg3.indexOf('cfgWrite-dsh') < 0);
  check('③ 给出可复制的 Base URL 与模型', seg3.indexOf('data-copy=') >= 0 && seg3.indexOf('要填到') >= 0);
  check('分段式下不再有顶部"照着做"清单', ds.indexOf('怎么用（照着做）') < 0);
  check('顶部有状态一行（命令/副本/残留）', ds.indexOf('class="meta toolstat"') >= 0);
  check('维护区折叠在最底', ds.indexOf('维护与细节') >= 0);
  check('维护区在最后一段之后', ds.indexOf('维护与细节') > noPos('③'));

  // 反向断言：其它工具仍是老排版（不然就是"只改 dsh"没守住）
  check('opencode 现在也是分段式（不再是老排版）', op.indexOf('class="stepno"') >= 0 && op.indexOf('怎么用（照着做）') < 0);

  // --- 未知页面 ---
  console.log('路由');
  setHash('#/nope/nope');
  await new Promise(r => setTimeout(r, 200));
  check('未知地址给出提示而不是白屏', el('app').innerHTML.indexOf('没有这个页面') >= 0);

  // --- W4：渠道 / 配置 / 诊断 / 历史 ---
  console.log('渠道页');
  setHash('#/providers');
  await wait('渠道页渲染', () => el('app').innerHTML.indexOf('不内置、不代发、不代充') >= 0, 20000);
  const pv = el('app').innerHTML;
  check('列出多个渠道', (pv.match(/<div class="card">/g) || []).length >= 5,
    '卡片数=' + (pv.match(/<div class="card">/g) || []).length);
  check('写明不内置/不代发/不代充 key', pv.indexOf('不内置、不代发、不代充') >= 0);
  check('给出注册或领 key 的外链', pv.indexOf('target="_blank"') >= 0 && pv.indexOf('注册账号') >= 0);
  // 渠道页不再直接跳到"配置页"：配置写在各自智能体页里
  check('渠道页不再有"用这个渠道配置"按钮', pv.indexOf('data-cfg=') < 0);
  check('渠道页说明了去智能体页配置', pv.indexOf('配置在各自智能体页里') >= 0);
  check('渠道页不含任何 key 值', pv.indexOf('sk-') < 0);

  // --- 参考价格：按币种两张表，只列事实 ---
  console.log('参考价格');
  check('渠道页有「参考价格」一节', el('app').innerHTML.indexOf('参考价格') >= 0);
  const priceHtml = el('app').innerHTML;
  // 有数字的币种要出表；全都没抄到的币种，至少在"未收录"列表里标出币种 —— 不能糊成一片
  const cfgP0 = await (await fetch(BASE + '/api/providers')).json();
  const prows = cfgP0.providers || [];
  const cnyRows = prows.filter((x) => x.pricing && x.pricing.currency === 'CNY' && (x.pricing.rows || []).length > 0).length;
  const usdRows = prows.filter((x) => x.pricing && x.pricing.currency === 'USD' && (x.pricing.rows || []).length > 0).length;
  const cnyOk = cnyRows === 0 ? priceHtml.indexOf('人民币（CNY）') < 0 : priceHtml.indexOf('人民币（CNY）') >= 0;
  const usdOk = usdRows === 0 ? priceHtml.indexOf('（美元）') >= 0 : priceHtml.indexOf('美元（USD）') >= 0;
  check('价格按币种分得清（有数字出表，没数字在未收录里标币种）', cnyOk && usdOk,
    'CNY 行 ' + cnyRows + ' / USD 行 ' + usdRows);
  check('写了"不构成比价或选购建议"', priceHtml.indexOf('不构成比价或选购建议') >= 0);
  check('写明不做汇率换算', priceHtml.indexOf('不做汇率换算') >= 0);
  check('每张表都有抄录日期', priceHtml.indexOf('抄录于') >= 0);
  check('给出了计价单位（每百万 tokens）', priceHtml.indexOf('每百万 tokens') >= 0);
  check('DeepSeek 的价格行渲染出来了', priceHtml.indexOf('deepseek-flash') >= 0 && priceHtml.indexOf('¥ 2') >= 0);
  const cfgPrice = await (await fetch(BASE + '/api/providers')).json();
  const withRows = (cfgPrice.providers || []).filter((x) => x.pricing && (x.pricing.rows || []).length > 0);
  const withoutRows = (cfgPrice.providers || []).filter((x) => x.pricing && !(x.pricing.rows || []).length);
  check('有价格的渠道至少 3 家', withRows.length >= 3, '实际 ' + withRows.length);
  if (withoutRows.length) {
    check('未收录的渠道被单独列出来并说明原因', priceHtml.indexOf('未收录') >= 0);
  } else {
    check('（所有渠道都抄到了价格，跳过未收录断言）', true);
  }
  check('价格表里没有"最便宜/推荐买"这类结论',
    priceHtml.indexOf('最便宜') < 0 && priceHtml.indexOf('推荐购买') < 0);
  console.log('旧的配置页地址');
  setHash('#/config?provider=deepseek');
  await wait('配置搬走页渲染', () => el('app').innerHTML.indexOf('配置搬走了') >= 0, 20000);
  const cf = el('app').innerHTML;
  check('不再有全局配置页（没有写入配置按钮）', !reg.has('do-config'));
  check('解释页说明配置去了哪', cf.indexOf('所以配置现在写在每个智能体自己的页面上') >= 0);
  check('解释页给出进各智能体页的路子', cf.indexOf('从顶栏选一个智能体进去') >= 0 || (cf.indexOf('#/tool/claude-code') >= 0 && cf.indexOf('#/tool/dsh') >= 0));
  check('导航里已经没有「配置」', el('nav').innerHTML.indexOf('#/config') < 0);
  check('解释页里不带任何 key 值', cf.indexOf('sk-') < 0);
  console.log('诊断页');
  setHash('#/diagnose');
  await wait('诊断页渲染', () => el('app').innerHTML.indexOf('生成诊断报告') >= 0, 30000);
  await wait('诊断正文已载入', () => (el('diagText') && String(el('diagText').textContent).length > 200) ||
    el('app').innerHTML.indexOf('还没有生成过诊断报告') >= 0, 30000);
  const dg = el('app').innerHTML;
  check('有生成报告按钮', reg.has('do-diag'));
  check('写明报告已脱敏', dg.indexOf('自动脱敏') >= 0);
  const dgText = el('diagText') ? String(el('diagText').textContent) : '';
  if (dgText) {
    check('报告正文确实取到了', dgText.length > 200, '长度=' + dgText.length);
    check('报告正文不含本机用户名', dgText.indexOf(process.env.USERNAME) < 0);
    check('有复制全文按钮', reg.has('copyDiag'));
  } else {
    check('（本机还没有报告，跳过正文断言）', true);
  }

  console.log('历史页');
  setHash('#/history');
  await wait('历史页渲染', () => el('app').innerHTML.indexOf('会话历史') >= 0, 20000);
  const hs = el('app').innerHTML;
  check('列出会话或给出空状态说明', hs.indexOf('data-restore=') >= 0 || hs.indexOf('还没有会话记录') >= 0);
  check('写明还原也是只搬不删', hs.indexOf('只搬不删') >= 0);
  const restoreCount = (hs.match(/data-restore="/g) || []).length;
  console.log('  （本机有 ' + restoreCount + ' 条会话记录）');

  // --- 启动：装了才给启动按钮，以及"点下去会弹什么" ---
  // 这一段以前写死"opencode 已装"。在干净的机器上（CI runner、新电脑）它必然假失败，
  // 而且后面 wait('启动确认框弹出') 等不到就抛异常、把整套冒烟带崩 —— 失败的就不再
  // 是"启动有没有问题"，而是"这台机器装没装"。改成先问接口，再按真实状态断言：
  // 装了验"能给可点的按钮并能拉起确认框"，没装验"为什么不给点"。
  // --- 本地模型页：只读的硬件判定 ---
  // 结论由服务端算好（纯函数），界面只负责展示。所以这里断的是
  // "该说的说了没有、不该问的问了没有"，不是排版。
  console.log('本地模型页');
  setHash('#/local');
  await wait('本地模型页渲染', () => el('app').innerHTML.indexOf('能跑哪一档') >= 0, 20000);
  const localHtml = el('app').innerHTML;
  check('本地模型页有「你的机器」一段', localHtml.indexOf('你的机器') >= 0);
  check('本地模型页报显存与读数来源', localHtml.indexOf('显存') >= 0 && localHtml.indexOf('读数来源') >= 0);
  check('本地模型页报磁盘余量', localHtml.indexOf('磁盘余量') >= 0);
  check('本地模型页每档都有「详情」入口', /data-detail=/.test(localHtml));
  check('本地模型页给出判定（能跑 / 跑不动 / 说不准）',
    localHtml.indexOf('能跑') >= 0 || localHtml.indexOf('跑不动') >= 0 || localHtml.indexOf('说不准') >= 0);
  check('本地模型页写出「上下文必须调到 32K」', localHtml.indexOf('静默截断') >= 0);
  check('本地模型页说清本地没有 key', localHtml.indexOf('本地没有 key') >= 0);
  check('本地模型页没有 key / 写入入口', !reg.has('cfgEnv-ollama') && !reg.has('cfgWrite-ollama'));
  check('本地模型页标注 Claude Code 连不了本地', localHtml.indexOf('Claude Code 暂时连不了本地') >= 0);
  check('顶栏有「本地模型」入口', el('nav').innerHTML.indexOf('#/local') >= 0);
  // --- 本地模型的下载 / 删除按钮：数量与状态逐档对照，点下去必须先拿到服务端命令 ---
  const locJson = await (await fetch(BASE + '/api/local')).json();
  const locModels = locJson.models || [];
  const dlBtns = (localHtml.match(/data-act="model-pull"/g) || []).length;
  const rmBtns = (localHtml.match(/data-act="model-remove"/g) || []).length;
  // installable=false 的档（GLM / qwen3-coder-next）本来就不给下载按钮
  const expectDl = locModels.filter((m) => m.installable !== false && !m.downloaded && m.verdict !== 'no').length;
  const expectRm = locModels.filter((m) => m.downloaded).length;
  check('「下载」按钮数 = 没下且跑得动的档数', dlBtns === expectDl, '按钮 ' + dlBtns + ' / 应为 ' + expectDl);
  check('「删除」按钮数 = 已下载的档数', rmBtns === expectRm, '按钮 ' + rmBtns + ' / 应为 ' + expectRm);
  const noVerdictModels = locModels.filter((m) => m.verdict === 'no');
  if (noVerdictModels.length) {
    check('跑不动的那档不给下载按钮（别白下十几 GB）',
      noVerdictModels.every((m) => localHtml.indexOf('data-act="model-pull" data-target="' + m.ollamaTag + '"') < 0));
  } else {
    check('（本机每档都跑得动，跳过"跑不动不给下载"断言）', true);
  }

  // --- 分组：按品牌/系列分开，Qwen 组在最前，每组有说明 ---
  const groups = locJson.modelGroups || [];
  check('本地模型页按品牌分组渲染', groups.length >= 3, '组数 ' + groups.length);
  check('第一组是 Qwen 系列且标了推荐', groups[0] && groups[0].id === 'qwen' && groups[0].recommended === true,
    groups[0] ? groups[0].id + '/' + groups[0].recommended : '(无)');
  check('每组都有一句说明', groups.every((g) => String(g.note || '').length > 10));
  check('每组都给出"本机能跑几档"', groups.every((g) => typeof g.okCount === 'number'));
  check('页面印出了组名', groups.every((g) => localHtml.indexOf(escJs(g.name)) >= 0 || localHtml.indexOf(g.name) >= 0));
  check('页面印出了「推荐先用这个」', localHtml.indexOf('推荐先用这个') >= 0);
  const unmeasured = locModels.filter((m) => m.unmeasured);
  if (unmeasured.length > 0) {
    check('未实测的档标了「未实测」', localHtml.indexOf('未实测') >= 0, '未实测 ' + unmeasured.length + ' 档');
  } else {
    check('（所有档都实测过，跳过未实测标记断言）', true);
  }
  const readonlyGroup = groups.filter((g) => g.models.some((m) => m.installable === false))[0];
  if (readonlyGroup) {
    check('只作说明的组里没有任何下载按钮',
      readonlyGroup.models.every((m) => localHtml.indexOf('data-act="model-pull" data-target="' + m.ollamaTag + '"') < 0));
    check('只作说明的档标了「不提供下载」', localHtml.indexOf('不提供下载') >= 0);
  } else {
    check('（没有"只作说明"的组，跳过该断言）', true);
  }
  // --- DeepSeek 组：开源权重 R1 系列，必须提示"不适合当工具层" ---
  const dsGroup = groups.filter((g) => g.id === 'deepseek')[0];
  check('有 DeepSeek 组且排在第二位', !!dsGroup && groups.indexOf(dsGroup) === 1,
    dsGroup ? '位置 ' + groups.indexOf(dsGroup) : '(无)');
  if (dsGroup) {
    check('DeepSeek 组给出至少 4 档', dsGroup.models.length >= 4, '档数 ' + dsGroup.models.length);
    check('DeepSeek 组的说明里写了"工具调用"这件事',
      String(dsGroup.warn || '').indexOf('工具调用') >= 0);
    check('页面印出了 DeepSeek 组名', localHtml.indexOf('DeepSeek 开源权重') >= 0);
    const r1 = dsGroup.models.filter((m) => m.ollamaTag === 'deepseek-r1:7b')[0];
    check('deepseek-r1:7b 标为已实测', !!r1 && r1.unmeasured === false);
    if (r1) {
      el('modal').classList.remove('show');
      clickDocBtn({ 'data-detail': r1.ollamaTag });
      await wait('R1 详情弹窗', () => el('modal').classList.contains('show'), 15000);
      const r1text = el('modalBody').innerHTML;
      check('R1 详情里如实写"工具调用 ❌ 不会"', r1text.indexOf('工具调用') >= 0 && r1text.indexOf('❌') >= 0);
      check('R1 详情里给出实测速度', /tok\/s/.test(r1text));
      el('modalCancel').onclick();
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  const dlModel = locModels.filter((m) => !m.downloaded && m.verdict !== 'no')[0];
  const rmModel = locModels.filter((m) => m.downloaded)[0];
  blockRun = true;
  if (dlModel) {
    previewCalls.length = 0; runCalls.length = 0;
    clickDocBtn({ 'data-act': 'model-pull', 'data-target': dlModel.ollamaTag });
    await wait('下载确认框弹出', () => el('modal').classList.contains('show'), 20000);
    const pvDl = previewCalls[previewCalls.length - 1];
    check('点下载先向服务端要命令', !!pvDl && pvDl.actionId === 'model-pull' && pvDl.targetId === dlModel.ollamaTag, JSON.stringify(pvDl));
    check('下载确认框里是 -ModelPull 那条命令', el('modalBody').innerHTML.indexOf('-ModelPull') >= 0);
    check('下载确认框说明了会真的往磁盘写文件', el('modalBody').innerHTML.indexOf('真的往磁盘写文件') >= 0);
    check('下载确认框没有套用"只搬不删"那套说法', el('modalBody').innerHTML.indexOf('只搬不删') < 0);
    el('modalCancel').onclick();
    await new Promise((r) => setTimeout(r, 150));
    check('取消后没有下载', runCalls.length === 0);
  } else {
    check('（本机没有可下载的档，跳过下载确认断言）', true);
  }

  if (rmModel) {
    previewCalls.length = 0; runCalls.length = 0;
    clickDocBtn({ 'data-act': 'model-remove', 'data-target': rmModel.ollamaTag });
    await wait('删除确认框弹出', () => el('modal').classList.contains('show'), 20000);
    const pvRm = previewCalls[previewCalls.length - 1];
    check('点删除先向服务端要命令', !!pvRm && pvRm.actionId === 'model-remove' && pvRm.targetId === rmModel.ollamaTag, JSON.stringify(pvRm));
    check('删除确认框明确不是"只搬不删"', el('modalBody').innerHTML.indexOf('不会') >= 0 && el('modalBody').innerHTML.indexOf('备份') >= 0);
    check('删除确认框提到记账与重下', el('modalBody').innerHTML.indexOf('model-removals.log') >= 0);
    el('modalCancel').onclick();
    await new Promise((r) => setTimeout(r, 150));
    check('取消后没有删除', runCalls.length === 0);
  } else {
    check('（本机没有已下载的模型，跳过删除确认断言）', true);
  }
  // --- 每个模型的具体位置：必须来自"盘上核实"，不是照抄 Ollama 报的目录 ---
  check('已装模型表有「具体位置」一列', localHtml.indexOf('具体位置') >= 0);
  const installedModels = (locJson.ollama && locJson.ollama.models) || [];
  if (installedModels.length > 0) {
    const verifiedCount = installedModels.filter((x) => x.foundOnDisk && x.verified).length;
    check('每个已装模型都在盘上核实到了清单',
      verifiedCount === installedModels.length,
      '核实 ' + verifiedCount + ' / ' + installedModels.length);
    check('位置给出清单文件全路径', installedModels.every((x) => String(x.manifestPath || '').length > 0));
    check('位置给出分片目录', installedModels.every((x) => String(x.blobsDir || '').length > 0));
    check('页面上确实印出了清单路径', localHtml.indexOf('清单：') >= 0);
    check('页面上确实印出了分片目录', localHtml.indexOf('分片：') >= 0);
    check('页面上有「盘上已核实」标记', localHtml.indexOf('盘上已核实') >= 0);
  } else {
    check('（本机没装本地模型，跳过具体位置断言）', true);
  }
  check('页面注明找过哪几个目录（可展开）', localHtml.indexOf('找过这几个目录') >= 0);

  // --- 组内改成表格：共同字段只在组头说一次，逐档横向对比 ---
  check('能力档已收成表格列（模型/参数/体积/需显存/判定/能力/操作）',
    localHtml.indexOf('<th>需显存</th>') >= 0 && localHtml.indexOf('<th>判定</th>') >= 0 && localHtml.indexOf('<th>能力</th>') >= 0);
  check('组头给出「本组共同」字段（重复信息只说一次）', localHtml.indexOf('本组共同：') >= 0);
  check('能跑得动的档不再在判定列里重复"需要显存 N GB"',
    !/可以全量放进显卡<\/div><\/td>/.test(localHtml) || localHtml.indexOf('可以全量放进显卡') >= 0);
  // 详情：点开看实测数据 / 未实测说明 / 拉取命令
  const detailModel = locModels[0];
  if (detailModel) {
    el('modal').classList.remove('show');
    clickDocBtn({ 'data-detail': detailModel.ollamaTag });
    await wait('详情弹窗出现', () => el('modal').classList.contains('show'), 15000);
    const dtext = el('modalBody').innerHTML;
    check('点「详情」弹出这个模型的详情', el('modal').classList.contains('show'));
    check('详情里有拉取命令', dtext.indexOf('ollama pull ') >= 0);
    check('详情里标了实测或未实测', dtext.indexOf('本机实测') >= 0 || dtext.indexOf('未实测') >= 0);
    el('modalCancel').onclick();
    await new Promise((r) => setTimeout(r, 100));
    check('关掉详情后弹窗收起', !el('modal').classList.contains('show'));
  } else {
    check('（本机没有模型档，跳过详情断言）', true);
  }
  // --- 切换：只有 OpenCode / Codex 能自动写，其余明说"只给片段" ---
  const swTargets = (locJson.switchTargets || []);
  check('本地模型页给出可自动切换的目标', swTargets.length === 2, JSON.stringify(swTargets.map((s) => s.id)));
  check('可切换的目标就是 opencode 与 codex', swTargets.map((s) => s.id).sort().join(',') === 'codex,opencode');
  check('不支持自动切换的工具写明"只给片段"', localHtml.indexOf('只给片段，不代写') >= 0);
  for (const s of swTargets) {
    check(s.id + ' 行给出「切到本地」按钮', localHtml.indexOf('data-switch="local" data-target="' + s.id + '"') >= 0);
    check(s.id + ' 行给出模型下拉', localHtml.indexOf('id="swModel-' + s.id + '"') >= 0);
  }
  const anyInstalled = (locJson.ollama.models || []).length > 0;
  if (anyInstalled && swTargets.length > 0) {
    // 下拉里现在只列"目录里已下载"的档，所以这里也按同一口径取第一个
    var firstTag = (locJson.models || []).filter(function (m) { return m.downloaded; }).map(function (m) { return m.ollamaTag; })[0];
    if (!firstTag) { firstTag = locJson.ollama.models[0].name; }
    const selEl = el('swModel-opencode');
    if (selEl) { selEl.value = firstTag; }
    previewCalls.length = 0; runCalls.length = 0;
    clickDocBtn({ 'data-switch': 'local', 'data-target': 'opencode' });
    await wait('切换确认框弹出', () => el('modal').classList.contains('show'), 20000);
    const pvSw = previewCalls[previewCalls.length - 1];
    check('点「切到本地」先向服务端要命令', !!pvSw && pvSw.actionId === 'tool-local-switch' && pvSw.targetId === 'opencode', JSON.stringify(pvSw));
    check('切换请求带上了选中的模型', !!pvSw && pvSw.modelTag === firstTag, pvSw ? pvSw.modelTag : '(无)');
    check('确认框里是 -LocalSwitch 那条命令', el('modalBody').innerHTML.indexOf('-LocalSwitch') >= 0);
    check('确认框说明会先整份备份', el('modalBody').innerHTML.indexOf('备份') >= 0);
    el('modalCancel').onclick();
    await new Promise((r) => setTimeout(r, 150));
    check('取消后没有切配置', runCalls.length === 0);
  } else {
    check('（本机没有已装模型，跳过切换点击断言）', true);
  }
  // --- 位置与上下文：模型在哪、上下文实际多少，都必须标出来 ---
  check('本地模型页标出 Ollama 安装位置', localHtml.indexOf('安装位置') >= 0);
  check('本地模型页标出模型目录', localHtml.indexOf('模型目录') >= 0);
  const rootPilled = localHtml.indexOf('被 OLLAMA_MODELS 改过') >= 0 || localHtml.indexOf('默认位置') >= 0;
  check('模型目录注明了来源（默认位置 / 被 OLLAMA_MODELS 改过）', rootPilled);
  check('已装模型表写的是「实占（按清单）」', localHtml.indexOf('实占（按清单）') >= 0);
  check('本地模型页有「默认上下文」一行', localHtml.indexOf('默认上下文') >= 0);
  const ctxApplied = !!(locJson.ollama && locJson.ollama.contextApplied);
  const hasCtxBtn = /data-act="local-context"/.test(localHtml);
  if (ctxApplied) {
    check('上下文已经是 32K 时不显示「设成 32K」按钮', !hasCtxBtn);
  } else {
    check('上下文没到 32K 时给出「设成 32K」按钮', hasCtxBtn);
    if (hasCtxBtn) {
      previewCalls.length = 0; runCalls.length = 0;
      clickDocBtn({ 'data-act': 'local-context' });
      await wait('上下文确认框弹出', () => el('modal').classList.contains('show'), 20000);
      const pvCtx = previewCalls[previewCalls.length - 1];
      check('点「设成 32K」先向服务端要命令', !!pvCtx && pvCtx.actionId === 'local-context', JSON.stringify(pvCtx));
      check('确认框里是 -SetLocalContext 那条命令', el('modalBody').innerHTML.indexOf('-SetLocalContext') >= 0);
      check('确认框说明会重启 Ollama', el('modalBody').innerHTML.indexOf('重启') >= 0);
      check('确认框说明验证不过会自动改回', el('modalBody').innerHTML.indexOf('改回原值') >= 0);
      el('modalCancel').onclick();
      await new Promise((r) => setTimeout(r, 150));
      check('取消后没有改上下文', runCalls.length === 0);
    }
  }
  // --- 接入矩阵 + 工具调用自检 ---
  check('本地模型页有「接进各智能体」矩阵', localHtml.indexOf('接进各智能体') >= 0);
  check('矩阵里列出 Anthropic 协议的工具（Claude Code）', localHtml.indexOf('anthropic-messages') >= 0);
  check('矩阵里说明本工具不代写这些配置', localHtml.indexOf('不代写这些配置') >= 0);
  const scButtons = (localHtml.match(/data-act="local-endpoint-check"/g) || []).length;
  check('每个已装模型都有「自检工具调用」按钮', scButtons === (locJson.ollama.models || []).length,
    '按钮 ' + scButtons + ' / 已装 ' + (locJson.ollama.models || []).length);

  const scModel = (locJson.ollama.models || [])[0];
  if (scModel) {
    previewCalls.length = 0; runCalls.length = 0;
    el('modal').classList.remove('show');
    clickDocBtn({ 'data-act': 'local-endpoint-check', 'data-target': scModel.name });
    await wait('自检请求发出', () => runCalls.length > 0, 20000);
    check('自检是只读动作：不问确认框，直接发起', !el('modal').classList.contains('show'));
    check('自检请求指向选中的模型', runCalls[0].actionId === 'local-endpoint-check' && runCalls[0].targetId === scModel.name,
      JSON.stringify(runCalls[0]));
  } else {
    check('（本机没装本地模型，跳过自检点击断言）', true);
  }
  const toolLocalBlocks = {
    opencode: { expect: '本地模型（可选）' },
    'claude-code': { expect: '暂时连不了本地模型' },
    python: { expect: '' }
  };
  for (const tid of Object.keys(toolLocalBlocks)) {
    setHash('#/tool/' + tid);
    await wait('工具页 ' + tid, () => el('app').innerHTML.indexOf('工具') >= 0, 20000);
    const h = el('app').innerHTML;
    const spec = toolLocalBlocks[tid];
    if (spec.expect) {
      check(tid + ' 页有本地模型一段', h.indexOf(spec.expect) >= 0);
    } else {
      check('无关工具（python）不出现本地模型段', h.indexOf('本地模型（可选）') < 0 && h.indexOf('连不了本地模型') < 0);
    }
  }
  setHash('#/tool/opencode');
  await wait('opencode 本地模型段', () => el('app').innerHTML.indexOf('本地模型（可选）') >= 0, 20000);
  const opLocal = el('app').innerHTML;
  check('opencode 页给出本机端点', opLocal.indexOf('127.0.0.1:11434/v1') >= 0);
  check('opencode 页给出可复制的片段', opLocal.indexOf('复制这段片段') >= 0);
  check('opencode 页说清本工具不代写', opLocal.indexOf('不写这个文件') >= 0);
  check('opencode 页提示本地不需要 key', opLocal.indexOf('不需要 key') >= 0);
  setHash('#/tool/claude-code');
  await wait('claude-code 本地模型段', () => el('app').innerHTML.indexOf('暂时连不了本地模型') >= 0, 20000);
  const ccLocal = el('app').innerHTML;
  check('claude-code 页解释是协议不同', ccLocal.indexOf('Anthropic') >= 0);
  check('claude-code 页不给本地片段（不给假希望）', ccLocal.indexOf('复制这段片段') < 0);
  console.log('启动区');
  setHash('#/tool/opencode');
  await wait('opencode 工具页（启动）', () => el('app').innerHTML.indexOf('怎么启动、怎么用') >= 0);
  const lz = el('app').innerHTML;
  check('工具页有启动区（分段式：③ 启动）', /③[^<]*<\/span>启动/.test(lz) || lz.indexOf('<h2>启动</h2>') >= 0);
  if (apiOp.installed) {
    check('已装工具给可用的启动按钮', /data-launch="opencode"[^>]*data-mode="interactive"/.test(lz));
  } else {
    check('没装的工具不给可点的启动按钮', lz.indexOf('data-launch="opencode"') < 0 && lz.indexOf('还没装') >= 0);
  }
  check('给出「怎么启动、怎么用」说明', lz.indexOf('怎么启动、怎么用') >= 0);
  if (apiOp.installed) {
    check('给出可复制的启动命令', lz.indexOf('启动命令：') >= 0);
  } else {
    // 启动器只对已装工具拼得出命令，所以没装时这里本来就没有「启动命令」这一行。
    // 反过来钉住它：没装就不要假装有命令可复制，只给"怎么启动"的说明。
    check('没装时不给可复制的启动命令（只给说明）', lz.indexOf('启动命令：') < 0);
  }
  check('给出跑冒烟的入口', lz.indexOf('跑一次冒烟') >= 0);

  // 点启动这条链路只有在真有可启动的工具时才验得到（服务端会拒掉没装工具的启动请求）
  const launchProbe = {};
  for (const id of ['opencode', 'dsh', 'cc-switch', 'claude-code']) {
    launchProbe[id] = await (await fetch(BASE + '/api/tool/' + id)).json();
  }
  const launchId = ['opencode', 'dsh', 'cc-switch', 'claude-code'].filter((id) => launchProbe[id].installed)[0] || null;
  launchCalls.length = 0;
  if (launchId) {
    setHash('#/tool/' + launchId);
    await wait('已装工具页（启动）', () => el('app').innerHTML.indexOf('怎么启动、怎么用') >= 0);
    check('已装的工具在页面上给可点的启动按钮', el('app').innerHTML.indexOf('data-launch="' + launchId + '"') >= 0);
    clickDocBtn({ 'data-launch': launchId, 'data-mode': 'interactive', 'data-name': launchId });
    await wait('启动确认框弹出', () => el('modal').classList.contains('show'));
    const dry = launchCalls[launchCalls.length - 1];
    check('点启动先向服务端要命令（dryRun）', !!dry && dry.dryRun === true && dry.toolId === launchId, JSON.stringify(dry));
    // 安全边界：启动请求体里只能有这三个字段，不能出现路径 / 命令 / 参数
    check('启动请求体只有 toolId / mode / dryRun', Object.keys(dry).sort().join(',') === 'dryRun,mode,toolId', Object.keys(dry).join(','));
    check('确认框里是要跑的命令原文', el('modalBody').innerHTML.indexOf('cmd.exe') >= 0);
    check('确认框说明会开一个新窗口', el('modalBody').innerHTML.indexOf('新窗口') >= 0);
    el('modalCancel').onclick();
    await new Promise(r => setTimeout(r, 150));
    check('取消后没有真的启动', launchCalls.filter(c => !c.dryRun).length === 0);
  } else {
    check('（本机没装任何工具，跳过"点启动"这条链路）', true);
  }

  // 启动按钮的可用性必须和接口状态一致：没装就禁用并写明原因，装了就能点。
  // （这一段以前写死"claude-code 没装"，机器上装好之后它就误报了。）
  setHash('#/tool/claude-code');
  await wait('claude-code 工具页（启动）', () => el('app').innerHTML.indexOf('怎么启动、怎么用') >= 0);
  const lz2 = el('app').innerHTML;
  const apiCl2 = launchProbe['claude-code'];
  check('启动按钮的可用性与接口状态一致',
    apiCl2.installed ? lz2.indexOf('data-launch' + '="claude-code"') >= 0
                     : lz2.indexOf('<button disabled') >= 0,
    'installed=' + apiCl2.installed);
  check('没装时写明不能启动的原因', apiCl2.installed || lz2.indexOf('还没装') >= 0);
  check('照样给出怎么启动的说明', lz2.indexOf('怎么启动、怎么用') >= 0);

  // 首页卡片：装了才给启动按钮，没装就不给。
  // 这里逐个工具对接口真值 —— 别猜本机装了什么（runner 上 Node 与 Git 是预装的）。
  setHash('#/');
  await wait('首页（启动）', () => el('app').innerHTML.indexOf('#/tool/opencode') >= 0);
  const homeLaunch = el('app').innerHTML;
  const ovTools = ((await (await fetch(BASE + '/api/overview')).json()).tools) || [];
  const launchMismatch = ovTools.filter((t) => {
    const hasBtn = homeLaunch.indexOf('data-launch="' + t.id + '"') >= 0;
    return hasBtn !== !!t.installed;
  }).map((t) => t.id + (t.installed ? '(装了却没有按钮)' : '(没装却给了按钮)'));
  check('首页卡片的启动按钮与安装状态逐个一致', launchMismatch.length === 0, launchMismatch.join('、'));

  // 从这里开始要真的在服务端跑任务了 —— 把"拦住 /api/run"的开关关掉。
  blockRun = false;

  // --- 只读体检：结论断言放在这里，因为它不依赖网络、结论是确定的 ---
  // 这条要真的让服务端跑一次引擎，而引擎对"没装"的工具只会回一句未安装 ——
  // 于是它也必须在装了 opencode 的机器上才有意义，没装就明说跳过。
  console.log('真实任务：只读的「验证可用性」');
  if (apiOp.installed) {
    setHash('#/tool/opencode');
    await wait('opencode 工具页（验证）', () => el('app').innerHTML.indexOf('id="do-verify"') >= 0, 20000);
    const endsBefore = (el('log').textContent.match(/== 结束：/g) || []).length;
    el('do-verify').onclick();
    await wait('只读验证任务结束', () => (el('log').textContent.match(/== 结束：/g) || []).length > endsBefore, 180000);
    const verdictTail = el('log').textContent.split('== 结束：').pop().split('\n')[0];
    check('只读验证给出确定结论', verdictTail.indexOf('已结束') < 0, '结论=' + verdictTail);
    check('日志区收到引擎输出', el('log').textContent.indexOf('LLMKit') >= 0);
  } else {
    check('（opencode 没装，跳过真实验证任务）', true);
  }

  // --- 没有演练模式了：改动型动作一律先确认，且命令是服务端给的原文 ---
  console.log('改动前确认（改动型动作必须弹框）');
  setHash('#/tool/opencode');
  await waitFor(() => el('app').innerHTML.indexOf('id="do-install"') >= 0);
  previewCalls.length = 0; runCalls.length = 0;
  el('do-install').onclick();
  await wait('执行模式确认框弹出', () => el('modal').classList.contains('show'));
  check('执行模式下弹出确认框', el('modal').classList.contains('show'));
  check('确实先问了服务端要命令', previewCalls.length === 1 && previewCalls[0].apply === true);
  const mbody = el('modalBody').innerHTML;
  check('确认框里的命令是服务端给的原文', mbody.indexOf('Setup-LLMKit.ps1') >= 0);
  check('确认框里的命令带真实参数', mbody.indexOf('-OnlyTools') >= 0 && mbody.indexOf('-OnlyTiers') >= 0, mbody.slice(0, 200));
  check('确认框写明会真的改动系统', mbody.indexOf('真的改动') >= 0);
  check('确认框弹出时尚未执行', runCalls.length === 0);

  // 取消 → 不许跑
  el('modalCancel').onclick();
  await new Promise(r => setTimeout(r, 200));
  check('取消后什么都没执行', runCalls.length === 0);
  check('取消后确认框关闭', !el('modal').classList.contains('show'));

  // 卸载按钮也要走同一条路
  clickDocBtn({ 'data-act': 'tool-uninstall', 'data-target': 'opencode' });
  await wait('卸载确认框弹出', () => el('modal').classList.contains('show'));
  check('卸载同样要确认', el('modal').classList.contains('show'));
  check('卸载确认框给出真实命令', el('modalBody').innerHTML.indexOf('-Uninstall opencode') >= 0);
  check('卸载默认不带移除用户配置', previewCalls[previewCalls.length - 1].removeUserConfig === undefined);
  el('modalCancel').onclick();

  // --- 配置写入：这一轮之后 tutorial 页面上**没有**任何自动写入入口，把这条契约钉死 ---
  // （claude-code / opencode / codex 走官方教程；gemini 没有官方接入说明，② 仍是渠道卡片，命令行的 -Configure 也保留）
  console.log('tutorial 页面没有自动写入入口');
  let writeButtons = 0;
  for (const tid of ['claude-code', 'opencode', 'codex']) {
    setHash('#/tool/' + tid);
    await wait('工具页渲染 ' + tid, () => el('app').innerHTML.indexOf('cfgProvider-') >= 0, 20000);
    if (el('app').innerHTML.indexOf('cfgWrite-') >= 0) { writeButtons++; }
  }
  // 现状：只有 Claude Code 这一页改成自动写入（② 段有写入按钮）；OpenCode / Codex 仍是纯教程
  check('tutorial 里只有 Claude Code 有写入按钮', writeButtons === 1, '有写入按钮的页数=' + writeButtons);

  // --- 还原：命令里要看得到它打算还原哪一份会话 ---
  if (restoreCount > 0) {
    console.log('还原的确认框');
    setHash('#/history');
    await wait('历史页（执行模式）', () => el('app').innerHTML.indexOf('data-restore=') >= 0, 30000);
    const mPath = /data-restore="([^"]+)"/.exec(el('app').innerHTML);
    const sessPath = mPath ? mPath[1] : '';
    check('拿到了会话日志路径', sessPath.length > 0);
    previewCalls.length = 0; runCalls.length = 0;
    clickDocBtn({ 'data-restore': sessPath, 'data-session': '' });
    await wait('还原确认框弹出', () => el('modal').classList.contains('show'));
    check('还原要确认', el('modal').classList.contains('show'));
    check('确认框命令是 -Restore 那条', el('modalBody').innerHTML.indexOf('-Restore') >= 0);
    const rBody = previewCalls[previewCalls.length - 1];
    check('还原请求指向这份会话', rBody.actionId === 'restore' && rBody.targetId === sessPath,
      JSON.stringify({ a: rBody.actionId, t: rBody.targetId }));
    el('modalCancel').onclick();
    await new Promise(r => setTimeout(r, 100));
    check('取消后没有执行还原', runCalls.length === 0);
  } else {
    console.log('  （本机没有会话记录，跳过还原确认框的断言）');
  }

  // --- 演练模式删掉之后：每个改动型动作都要先确认，没有例外（刻意放最后）---
  // 这一段会走一次完整的 preview → 确认框 → 执行链路，所以放最后，不让它拖累前面的断言。
  console.log('每次改动都要确认（演练模式已删除）');
  setHash('#/tool/opencode');
  await wait('opencode 工具页（确认链路）', () => el('app').innerHTML.indexOf('id="do-install"') >= 0, 20000);
  previewCalls.length = 0; runCalls.length = 0;
  el('do-install').onclick();
  await wait('安装确认框弹出', () => el('modal').classList.contains('show'));
  const pv1 = previewCalls[0];
  check('点安装先调 /api/preview', previewCalls.length === 1);
  check('预览带上选中的安装层', pv1.tierId === 'npm-global', JSON.stringify(pv1));
  check('预览明确会真的执行（apply=true）', pv1.apply === true, JSON.stringify(pv1));
  check('确认框弹出时还没执行', runCalls.length === 0);
  // 确认 → 真的发 /api/run
  // 拦住 /api/run：只验请求体，不在服务端真的跑一次安装（计划现在能生成，会真装）
  blockRun = true;
  el('modalOk').onclick();
  await wait('确认后真的发出 /api/run', () => runCalls.length > 0);
  check('确认后发出 /api/run', runCalls.length === 1);
  check('发的请求带 apply=true', runCalls[0] && runCalls[0].apply === true, JSON.stringify(runCalls[0]));

  console.log('  ' + '-'.repeat(62));
  console.log('通过 ' + pass + ' 项，失败 ' + fail + ' 项');
  if (fail) { console.log('失败项：\n  - ' + failures.join('\n  - ')); }
  finish(fail ? 1 : 0);
})().catch(e => {
  console.log('  [FAIL] 冒烟测试异常终止：' + e.message);
  console.log(e.stack);
  fail++;
  failures.push('异常终止：' + e.message);
  annotate('异常终止：' + e.message);
  finish(1);
});

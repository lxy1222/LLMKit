/*
 * LLMKit 本地网页版前端。
 *
 * 设计取舍：
 *   · 用 hash 路由（#/tool/opencode）而不是给服务端加页面路由 —— 服务端保持"只会
 *     提供静态文件 + JSON 接口"，页面怎么切是前端自己的事，刷新也不会 404。
 *   · 所有动作都先打 /api/preview 拿到**真正会执行的那条命令**，再决定要不要弹确认框。
 *     绝不在界面里自己拼命令 —— 拼出来的和真跑的不是一回事，那比没有确认框更糟。
 *   · 没有"演练模式"开关：动作一律真执行，破坏性动作一律先弹确认框（框里是服务端给的命令原文），
 *     下次打开就默认动系统的开关，那不是省事，是陷阱。
 */
(function () {
  'use strict';

  // ---------------------------------------------------------------- 小工具
  var $ = function (id) { return document.getElementById(id); };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function pill(text, cls) {
    return '<span class="pill ' + (cls || '') + '">' + esc(text) + '</span>';
  }
  function mono(s) { return '<span class="mono">' + esc(s) + '</span>'; }

  var VERDICT = {
    ok: '一切正常', warn: '基本可用，有需要留意的项', fail: '存在问题，需要处理',
    dryrun: '演练完成，未改动系统', unknown: '已结束'
  };

  // ---------------------------------------------------------------- 状态
  var S = {
    actions: [],
    overview: null,
    detail: {},        // toolId -> 工具详情（避免来回切页时重复请求）
    tier: {},          // toolId -> 当前选中的安装层
    clean: {},         // toolId -> 是否勾选"先清理残留"
    dropCfg: false,    // 卸载时是否同时移除用户配置
    providers: null, configOverview: null, provider: '', tokenEnv: '',
    providersFetching: false,
    cfg: {},           // toolId -> { provider, tokenEnv, model }：每个智能体各有一份
    diagnostic: null, diagError: '', sessions: null,
    job: null, since: 0, timer: null, jobTitle: '',
    collapsed: false
  };

  function actionMeta(id) {
    for (var i = 0; i < S.actions.length; i++) {
      if (S.actions[i].id === id) { return S.actions[i]; }
    }
    return { id: id, label: id, desc: '', destructive: true };
  }

  // 确认框里的说明必须按动作说实话：本地模型的删除是**真删**（不搬备份），
  // 照搬"只搬不删、可一键还原"那套说法就是在骗人 —— 磁盘上那几个 GB 已经没了。
  function confirmBullets(actionId) {
    if (actionId === 'model-pull') {
      return '<li>这一步会真的往磁盘写文件（几 GB），磁盘余量服务端已经算过，不够会直接拒绝。</li>' +
        '<li>下载过程会实时输出进度；结束后会回查一次「已装列表」，不是只看命令有没有报成功。</li>';
    }
    if (actionId === 'local-context') {
      return '<li>会改用户级环境变量 <b>OLLAMA_CONTEXT_LENGTH=32768</b>，并<b>重启一次 Ollama</b>（正在跑的任务会被中断）。</li>' +
        '<li>重启后会真的加载一个模型、读回生效值来验证；验证不过会<b>自动改回原值</b>并告诉你。</li>';
    }
    if (actionId === 'model-remove') {
      return '<li>这一步会真的删掉模型文件，<b>不会</b>挪到备份区 —— 一个模型几 GB，搬备份很可能把磁盘撑爆。</li>' +
        '<li>删了什么、多大、怎么装回来，会记在 out\\state\\model-removals.log；要恢复就是重新下载。</li>';
    }
    return '<li>被替换或移除的东西会先挪到备份区（只搬不删），并按会话写进日志。</li>' +
      '<li>事后可以在下面的日志里看到全过程，也可以按日志一键还原。</li>';
  }

  // ---------------------------------------------------------------- 接口
  function getJson(path) {
    return fetch(path, { cache: 'no-store' }).then(function (r) {
      return r.json().then(function (j) { return { status: r.status, body: j }; },
        function () { return { status: r.status, body: null }; });
    });
  }
  function postJson(path, body) {
    return fetch(path, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    }).then(function (r) {
      return r.json().then(function (j) { return { status: r.status, body: j }; },
        function () { return { status: r.status, body: null }; });
    });
  }

  // ---------------------------------------------------------------- 日志面板
  function setLog(text) { $('log').textContent = text; }

  function appendLog(line) {
    var el = $('log');
    if (el.textContent === '（还没有运行任何动作）') { el.textContent = ''; }
    el.textContent += (el.textContent ? '\n' : '') + line;
    el.scrollTop = el.scrollHeight;
  }

  function jobStatePill(state, verdict) {
    if (state === 'running') { return pill('运行中', 'run'); }
    if (state === 'failed') { return pill('失败', 'bad'); }
    if (state === 'stopped') { return pill('已停止', ''); }
    if (state === 'done') {
      if (verdict === 'fail') { return pill('存在问题', 'bad'); }
      if (verdict === 'dryrun') { return pill('演练完成', ''); }
      if (verdict === 'warn') { return pill('基本可用', 'warn'); }
      return pill('完成', 'done');
    }
    return pill(state || '空闲', '');
  }

  function busy() { return !!(S.job && S.timer); }

  function refreshJobHead() {
    $('logTitle').textContent = S.jobTitle || '日志';
    $('jobState').innerHTML = busy()
      ? jobStatePill('running')
      : (S.lastState ? jobStatePill(S.lastState, S.lastVerdict) : '');
  }

  // ---------------------------------------------------------------- 确认框
  var modalOk = null;

  function showModal(title, bodyHtml, okText, onOk) {
    $('modalTitle').innerHTML = esc(title);
    $('modalBody').innerHTML = bodyHtml;
    $('modalOk').textContent = okText;
    $('modalOk').className = 'danger';
    modalOk = onOk;
    $('modal').classList.add('show');
  }
  function hideModal() { $('modal').classList.remove('show'); modalOk = null; }

  function toast(msg) {
    var t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    setTimeout(function () { t.classList.remove('show'); }, 1800);
  }

  // ---------------------------------------------------------------- 执行动作
  function buildBody(actionId, extra) {
      // 已经没有「演练模式」这个开关：动作一律真执行，破坏性动作先弹确认框给你看命令原文
      var body = { actionId: actionId, targetId: '', apply: true };
    if (extra) { for (var k in extra) { if (extra[k] !== undefined && extra[k] !== '') { body[k] = extra[k]; } } }
    return body;
  }

  /*
   * 统一的动作入口。
   * 先预览（/api/preview 只算命令，不起任务），拿到 destructive / willApply 之后
   * 再决定：会真的改动系统 → 弹确认框并把命令原文摆出来；否则直接跑。
   */
  // 合并副本这种动作，光给命令行不够：要说清"保留哪份、挪走哪几份"。
  // 数据来自 /api/tool/<id>（conflictKeep / conflictMove），不是界面自己算的。
  function conflictDetailHtml(actionId, extra) {
    if (actionId !== 'tool-resolve-conflicts') { return ''; }
    var d = (S.detail && extra && extra.targetId) ? S.detail[extra.targetId] : null;
    if (!d) { return ''; }
    var moves = (d.conflictMove || []).map(function (x) { return '<li>' + mono(maskUserPath(x)) + '</li>'; }).join('');
    return '<div class="meta" style="margin-top:8px"><b>会保留：</b>' + mono(maskUserPath(d.conflictKeep) || '（PATH 命中的那份）') + '</div>' +
      (moves ? '<div class="meta">会挪到备份区（不删除，事后可在历史里还原）：</div><ul class="issues">' + moves + '</ul>' : '') +
      '<div class="note">只搬不删：被挪走的那几份不会消失，还原时按会话日志放回去。</div>';
  }

  function act(actionId, extra) {
    if (busy()) { toast('已有任务在跑，等它结束'); return; }
    var body = buildBody(actionId, extra);
    postJson('/api/preview', body).then(function (res) {
      if (res.status !== 200 || !res.body) {
        toast('无法生成命令：' + ((res.body && res.body.error) || res.status));
        return;
      }
      var p = res.body;
      if (p.destructive && p.willApply) {
        var desc = actionMeta(actionId).desc || '';
        var html = '<p>' + esc(desc) + '</p>' +
          '<ul>' +
          '<li>这一步会<b>真的改动这台电脑</b>。</li>' +
          confirmBullets(actionId) +
          '</ul>' +
          '<div class="cmd">' + esc(maskUserPath(p.commandLine)) + '</div>' +
          '<div class="note">这条就是即将执行的原文，你可以自己复制去命令行重跑。</div>' +
          conflictDetailHtml(actionId, extra);
        showModal(actionMeta(actionId).label + (extra && extra.targetId ? ' · ' + extra.targetId : ''), html, '确认执行', function () {
          hideModal(); startJob(body);
        });
      } else {
        startJob(body);
      }
    });
  }

  function startJob(body) {
    setLog('正在启动：' + body.actionId + (body.targetId ? ' · ' + body.targetId : ''));
    postJson('/api/run', body).then(function (res) {
      if (res.status === 409) {
        setLog('已有任务在运行，请等它结束。');
        return;
      }
      if (res.status !== 200 || !res.body) {
        setLog('启动失败：' + ((res.body && res.body.error) || res.status));
        return;
      }
      S.job = res.body.jobId; S.since = 0;
      S.jobTitle = actionMeta(body.actionId).label + (body.targetId ? ' · ' + body.targetId : '');
      S.lastState = null; S.lastVerdict = null;
        setLog('命令：' + res.body.commandLine + '\n');
      refreshJobHead();
      render();
      if (S.timer) { clearInterval(S.timer); }
      S.timer = setInterval(poll, 300);
    }).catch(function (e) { setLog('请求失败：' + e.message); });
  }

  function poll() {
    if (!S.job) { return; }
    getJson('/api/job/' + S.job + '?since=' + S.since).then(function (res) {
      var j = res.body;
      if (!j) { return; }
      if (j.lines && j.lines.length) {
        S.since = j.total;
        for (var i = 0; i < j.lines.length; i++) { appendLog(j.lines[i]); }
      }
      if (j.finished) {
        clearInterval(S.timer); S.timer = null; S.job = null;
        S.lastState = j.state; S.lastVerdict = j.verdict;
        appendLog('');
        appendLog('== 结束：' + (VERDICT[j.verdict] || j.state) +
          (j.exitCodeAvailable ? '（退出码 ' + j.exitCode + '）' : ''));
        refreshJobHead();
        // 状态肯定变了，把各页缓存清掉重取。
        // 这里必须连 overview 一起重取 —— 原来只清了 detail / configOverview / diagnostic / sessions，
        // 首页用的 S.overview 一直没失效，于是"装完了首页还显示未安装"。
        S.detail = {};
        S.configOverview = null;
        S.diagnostic = null;
        S.sessions = null;
        if (S.overview) { S.overview = null; }
        loadOverview().then(function () { render(); });
      }
    }).catch(function () { /* 服务重启时忽略这一拍 */ });
  }

  // ---------------------------------------------------------------- 启动工具
  /*
   * 启动一个工具。刻意**不复用 act()**：act 走的是任务队列（同一时刻只允许一个任务），
   * 而启动一个交互式 CLI 会一直占着窗口，走队列就等于把工具锁死。
   * 所以先用 dryRun 问服务端"到底要跑什么"，把原文摆给用户看清，再真的起。
   */
  function doLaunch(toolId, mode, label) {
    postJson('/api/launch', { toolId: toolId, mode: mode, dryRun: true }).then(function (res) {
      if (res.status !== 200 || !res.body) {
        toast((res.body && res.body.error) || ('无法启动：HTTP ' + res.status));
        return;
      }
      var p = res.body;
      var what = (mode === 'smoke')
        ? '跑一次冒烟：让这个工具真的问模型一句话，把回答打出来 —— 这是唯一能证明"key 通了、能用了"的办法。'
        : '启动 ' + label + '。';
      var html = '<p>' + esc(what) + '</p>' +
        '<ul>' +
        '<li>会开一个<b>新窗口</b>来跑它。关掉那个窗口不影响本工具，也不影响已经装好的东西。</li>' +
        '<li>窗口会留在那儿（成功失败都留），这样你看得到输出和报错。</li>' +
        '</ul>' +
        '<div class="cmd">' + esc(maskUserPath(p.commandLine)) + '</div>' +
        '<div class="note">启动目录：' + esc(maskUserPath(p.workingDir) || '（未指定）') + '</div>' +
        (p.uiHint ? '<div class="note">' + esc(p.uiHint) + '</div>' : '');
      showModal((mode === 'smoke' ? '跑一次冒烟 · ' : '启动 · ') + label, html, mode === 'smoke' ? '跑一次' : '启动', function () {
        hideModal();
        postJson('/api/launch', { toolId: toolId, mode: mode }).then(function (r2) {
          if (r2.status === 200 && r2.body && r2.body.ok) {
            appendLog('== 已启动：' + label + '\n命令：' + r2.body.commandLine);
            toast('已启动，去看新开的窗口');
          } else {
            toast((r2.body && r2.body.error) || ('启动失败：HTTP ' + r2.status));
          }
        });
      });
    });
  }

  // 只出卡片体（不含外层 <section> 与标题）：分段式排版要自己决定标题里写什么。
  function launchCardBody(d) {
    var L = d.launch;
    if (!L) { return '<div class="card"><div class="meta">这个工具没有登记启动方式。</div></div>'; }
    var steps = (L.howTo || []).map(function (s) { return '<li>' + esc(s) + '</li>'; }).join('');
    var acts = [];
    if (L.ok) {
      acts.push('<button class="primary" data-launch="' + esc(d.id) + '" data-mode="interactive" data-name="' + esc(d.name) + '">启动</button>');
    } else {
      acts.push('<button disabled title="' + esc(L.reason || '') + '">启动</button>');
    }
    if (L.smokeOk) {
      acts.push('<button data-launch="' + esc(d.id) + '" data-mode="smoke" data-name="' + esc(d.name) + '">跑一次冒烟（验证真的能用）</button>');
    } else if (L.smokeReason) {
      acts.push('<button disabled title="' + esc(L.smokeReason) + '">跑一次冒烟</button>');
    }
    var cmds = '';
    if (L.interactiveCommand) {
      cmds += '<div class="meta">启动命令：' + mono(maskUserPath(L.interactiveCommand)) +
        ' <button class="tiny" data-copy="' + esc(L.interactiveCommand) + '">复制</button></div>';
    }
    if (L.smokeCommand) {
      cmds += '<div class="meta">冒烟命令：' + mono(maskUserPath(L.smokeCommand)) +
        ' <button class="tiny" data-copy="' + esc(L.smokeCommand) + '">复制</button></div>';
    }
    // 服务型工具（例如 dsh web）会占一个端口：把最终选定的地址写出来，
    // 省得用户去窗口里找那一行 —— 端口被占时我们已经在服务端换过了。
    var addr = (L.port > 0)
      ? '<div class="meta">预计地址：http://127.0.0.1:' + L.port + '（起来后它会自己打开浏览器）</div>'
      : '';
    var why = (!L.ok && L.reason) ? '<div class="callout warn">暂时不能启动：' + esc(L.reason) + '</div>' : '';
    var smokeBlocked = (!L.smokeOk && L.smokeReason) ? '<div class="meta">冒烟不可用：' + esc(L.smokeReason) + '</div>' : '';
    return '<div class="card">' +
      '<div class="acts">' + acts.join('') + '</div>' + why + smokeBlocked + addr + cmds +
      (steps ? '<details><summary>怎么启动、怎么用</summary><ul>' + steps + '</ul></details>' : '') +
      (L.uiHint ? '<div class="callout">' + esc(L.uiHint) + '</div>' : '') +
      '</div>';
  }


  // ---------------------------------------------------------------- 首页
  function renderHome() {
    var ov = S.overview;
    if (!ov) { $('app').innerHTML = '<div class="card">读取状态中…</div>'; return; }

    // 工具按角色分组：agent 是你要拿去干活的智能体，provider-manager 是帮你管渠道的配套工具。
    // 混在一张网格里会让人以为 cc-switch 也是智能体 —— 它自己不调模型（它的版本命令和冒烟命令都是空的）。
    var all = ov.tools || [];
    var byId = {};
    all.forEach(function (t) { byId[t.id] = t; });

    function toolCard(t) {
      var cls = t.clean ? 'ok' : (t.installed ? 'warn' : '');
      var label = t.installed
        ? (t.clean ? (t.version || '已安装（版本读不到）') : '已安装但有残留')
        : '未安装';
      var issues = (t.issues && t.issues.length)
        ? '<ul class="issues">' + t.issues.map(function (i) { return '<li>' + esc(i) + '</li>'; }).join('') + '</ul>'
        : '';
      var arts = t.artifactCount
        ? '<button class="tiny" data-act="tool-artifacts" data-target="' + esc(t.id) + '">清理残留(' + t.artifactCount + ')</button>'
        : '';
      // 装了才给「启动」：没装的话点了只会得到一句"还没装"，不如不给
      var launchBtn = t.installed
        ? '<button class="tiny" data-launch="' + esc(t.id) + '" data-mode="interactive" data-name="' + esc(t.name) + '">启动</button>'
        : '';
      // 配套工具额外说清它管哪几个。名单来自配置里的 manages，不是写死的文案。
      var manages = ((t.manages || []).length)
        ? '<div class="meta">它管这几个用哪个渠道：' + esc((t.manages || []).map(function (id) {
            return (byId[id] && byId[id].name) || id;
          }).join('、')) + '</div>'
        : '';
      return '<div class="card"><h3><a href="#/tool/' + esc(t.id) + '">' + esc(t.name) + '</a>' +
        pill(label, cls) + '</h3>' +
        '<div class="meta">' + esc(maskUserPath(t.executable) || t.vendor || '') + '</div>' + manages + issues +
        '<div class="acts">' +
        '<button class="primary" data-open="' + esc(t.id) + '">' + (t.installed ? '打开 / 重装' : (t.canAutoInstall === false ? '打开 / 手动安装' : '打开 / 安装')) + '</button>' +
        (t.installed ? '<button class="tiny" data-open="' + esc(t.id) + '">配置</button>' : '') +
        launchBtn +
        '<button class="tiny" data-act="tool-verify" data-target="' + esc(t.id) + '">验证</button>' +
        arts +
        '</div></div>';
    }

    // 智能体在前、配套工具在后，最后是本地模型运行时。
    // 配套工具这一类现在有两种：
    //   provider-manager —— 帮你管渠道（cc-switch）
    //   companion        —— 帮你备环境（python 这类编程运行时）
    // 运行环境里的 Node / Git 也一起并到这一组：它们本来就是"配套"的东西，
    // 单独占一整节反而让首页多一层。
    //
    // runtime（Ollama）必须单独一组：它既不是智能体、也不是"不调模型"的配套工具，
    // 混进配套工具那组会让那句"这一组自己不调模型"当场说谎。
    var agents = all.filter(function (t) { return t.role === 'agent'; }).map(toolCard).join('');
    var companions = all.filter(function (t) { return t.role === 'provider-manager' || t.role === 'companion'; }).map(toolCard).join('');
    var runtimes = all.filter(function (t) { return t.role === 'runtime'; }).map(toolCard).join('');

    // 刷新按钮固定在顶栏（见 index.html），这里不再生成一个同 id 的按钮
    $('app').innerHTML =
      '<section><div class="callout"><b>注意：</b>先安装 Node.js，再安装 DeepSeek Harness；' +
      '完成之后，其他模型可以让 Harness 给你装（但要花费 token），不必局限于此项目。</div></section>' +

      '<section><h2>智能体（你要用它们干活）</h2><div class="grid">' +
      (agents || '<div class="card">没有工具配置</div>') + '</div></section>' +

      '<section><h2>配套工具（备环境、管渠道，不直接调模型）</h2><div class="grid">' +
      (companions || '<div class="card">没有工具配置</div>') + '</div>' +
      '<div class="callout">这一组自己不调模型：' +
      '<b>Node.js / Git</b> 是别的工具要用的运行环境、<b>Python</b> 是编程运行时、' +
      '<b>PyCharm</b> 是写 Python 的 IDE、<b>cc-switch</b> 帮你把「用哪个渠道、哪把 key」管起来。' +
      '每个都能单独装，装智能体之前先把它们备齐，后面少踩坑。</div>' +
      '<div class="acts" style="margin-top:10px">' +
      '<span class="note">每个配套工具都在它自己的页面里单独安装 —— 不再有"一起补齐"。</span>' +
      '</div></section>' +

      (runtimes ?
        '<section><h2>本地模型运行时（把模型跑在你自己机器上）</h2><div class="grid">' + runtimes + '</div>' +
        '<div class="callout">这一组的工具不联网、不花 token 费，代价是占磁盘、吃显存，能力也不如在线 API。' +
        '装好之后去 <a href="#/local">本地模型</a> 看你的机器能跑多大 —— 跑不动的那档会直接告诉你为什么。</div></section>' : '') +

      '<section><details><summary>关于这个工具</summary><p class="note">' +
      '只装到用户目录，不需要管理员权限，也不会删除你的文件 —— 所有改动都先挪到备份区并留日志，可以一键还原。<br>' +
      '本工具不内置、代发或代充任何 API Key；只提供各渠道的注册与创建 Key 的入口，key 始终由你自己创建和保管。<br>' +
      '服务只监听 127.0.0.1，不对外网开放。' +
      '</p></details></section>';

  }

  // ---------------------------------------------------------------- 工具页
  function tierHtml(toolId, tiers, selected) {
    return tiers.map(function (t) {
      var badges = '';
      if (t.isPreferred) { badges += pill('默认', 'ok'); }
      badges += t.needsAdmin ? pill('需要管理员', 'warn') : pill('不需要管理员', 'ok');
      if (!t.verified) { badges += pill('未验证', 'warn'); }
      if (t.isManual) { badges += pill('需手动', 'warn'); }
      var extra = '';
      if (t.package) { extra += '<div class="meta">包：' + mono(t.package) + '</div>'; }
      if (t.scriptUrl) { extra += '<div class="meta">脚本：' + mono(t.scriptUrl) + '</div>'; }
      if (t.installRoot) { extra += '<div class="meta">装到：' + mono(t.installRoot) + '</div>'; }
      // 手动层（例如 python 的官方安装器）必须给可点的链接 —— 否则"打开下载页"只是句空话
      if (t.manualUrl) {
        extra += '<div class="meta">下载页：<a href="' + esc(t.manualUrl) + '" target="_blank" rel="noreferrer">' +
          esc(t.manualUrl) + '</a> <button class="tiny" data-copy="' + esc(t.manualUrl) + '">复制链接</button></div>';
      }
      return '<label class="tier' + (t.id === selected ? ' sel' : '') + '" data-tier="' + esc(t.id) + '">' +
        '<input type="radio" name="tier" value="' + esc(t.id) + '"' + (t.id === selected ? ' checked' : '') + '>' +
        '<span><span class="tname">' + esc(t.label) + badges + '</span>' +
        '<div class="tdetail">' + esc(t.detail || '') + '</div>' + extra + '</span></label>';
    }).join('');
  }

  function installsHtml(d) {
    var rows = (d.installations || []).map(function (i) {
      return '<tr><td>' + esc(i.source || '') + '</td><td class="mono">' + esc(maskUserPath(i.path)) + '</td>' +
        '<td>' + esc(i.version || '') + '</td></tr>';
    }).join('');
    if (rows) {
      return '<table class="tbl"><thead><tr><th>来源</th><th>位置</th><th>版本</th></tr></thead><tbody>' +
        rows + '</tbody></table>';
    }
    return '<div class="card"><div class="meta">没有找到已安装的副本。' +
      (d.executable ? '不过命令 <span class="mono">' + esc(maskUserPath(d.executable)) + '</span> 能解析到。' : '') +
      '</div></div>';
  }

  function cfgHtml(d) {
    if (!d.configTargets || !d.configTargets.length) {
      return '<div class="card"><div class="meta">这个工具暂时没有登记配置文件目标。</div></div>';
    }
    return d.configTargets.map(function (c) {
      // kind=guidance 的目标本工具**不会写**（比如 OpenCode 的嵌套 provider、
      // DSH 的凭据、cc-switch 的 SQLite）。这里必须把它和"真会写入"的目标区分开，
      // 否则页面会宣称"只会改这几个字段"，而实际一个字节都不改 —— 那是骗人。
      var isGuide = (c.kind === 'guidance');
      var keys = (c.managedKeys && c.managedKeys.length)
        ? '<div class="meta">' + (isGuide ? '要你在这个工具里填的值：' : '只会改这几个字段：') +
          esc(c.managedKeys.join('、')) + '</div>'
        : '<div class="meta">' + (isGuide ? '需要你自己配置' : '没有登记受管字段') + '</div>';
      return '<div class="card"><h3>' + esc(c.label) +
        (c.exists ? pill('文件已存在', 'ok') : pill('文件还不存在', '')) +
        (isGuide ? pill('本工具不写它', '') : (c.verified ? '' : pill('写入方式未验证', 'warn'))) + '</h3>' +
        '<div class="meta">' + mono(c.path) + '</div>' + keys +
        (c.notes ? '<div class="meta">' + esc(c.notes) + '</div>' : '') +
        '<div class="acts"><button class="tiny" data-copy="' + esc(c.path) + '">复制路径</button></div></div>';
    }).join('');
  }

  // ---------------------------------------------------------------- 渠道与模型（每个智能体各一份）
  /*
   * 为什么不做"一个全局配置页"：每个智能体认的字段、能用的模型、能不能真写文件，
   * 全都不一样（Claude Code 能写 env 块；OpenCode 是嵌套结构；dsh 是私有凭据文件）。
   * 放一个页面里就得靠标签区分，用户还得先知道自己是哪种。
   * 所以配置就长在它自己的页面上：选渠道 → 填变量名 → 选模型 → 只写这一个工具。
   */
  function tokenEnvOf(providerId) {
    return String(providerId || '').toUpperCase().replace(/[^A-Z0-9]/g, '_') + '_KEY';
  }

  function ensureProviders() {
    if (S.providers || S.providersFetching) { return; }
    S.providersFetching = true;
    getJson('/api/providers').then(function (r) {
      S.providersFetching = false;
      if (r.status === 200) { S.providers = r.body.providers || []; render(); }
    });
  }

  function cfgState(id) {
    if (!S.cfg[id]) { S.cfg[id] = { provider: '', tokenEnv: '', model: '' }; }
    var st = S.cfg[id];
    var providers = S.providers || [];
    if (!providers.length) { return { st: st, sel: null, providers: providers, models: [] }; }
    var sel = null;
    for (var i = 0; i < providers.length; i++) { if (providers[i].id === st.provider) { sel = providers[i]; } }
    if (!sel) { sel = providers[0]; st.provider = sel.id; }
    if (!st.tokenEnv) { st.tokenEnv = tokenEnvOf(sel.id); }
    var models = sel.models || [];
    if (!st.model && models.length) { st.model = models[0]; }
    return { st: st, sel: sel, providers: providers, models: models };
  }

  // guidanceOnly：这个工具本工具**一个字节都不写**时，只把要填的值摆出来让人复制，
  // 不给"写入"按钮 —— 点了什么都不会发生，那比没有按钮更糟。
  function cfgCardBody(d, guidanceOnly) {
    var id = d.id;
    var m = d.models || {};
    if (!d.configTargets || !d.configTargets.length) {
      return '<div class="card"><div class="meta">' +
        '这个工具没有登记配置文件目标，本工具不会写它的配置。</div></div>';
    }
    var ctx = cfgState(id);
    if (!ctx.providers.length) { ensureProviders(); }
    var provOpts = ctx.providers.map(function (p) {
      return '<option value="' + esc(p.id) + '"' + (ctx.sel && p.id === ctx.sel.id ? ' selected' : '') + '>' +
        esc(p.name) + '</option>';
    }).join('');
    var modelOpts = ctx.models.map(function (x) { return '<option value="' + esc(x) + '"></option>'; }).join('');

    var mayWrite = d.configTargets.filter(function (c) { return c.kind !== 'guidance'; });
    var onlyGuide = d.configTargets.filter(function (c) { return c.kind === 'guidance'; });

    var modelFacts = '';
    if (m.field) { modelFacts += '<div class="meta">模型名写在：' + esc(m.field) + '</div>'; }
    if (m.writable) {
      modelFacts += '<div class="meta">本工具能<b>直接</b>把这个模型写进配置文件。</div>';
    } else {
      modelFacts += '<div class="meta">本工具<b>不写</b>这个工具的模型文件 —— 点「复制模型名」自己填过去。</div>';
    }
    if (m.note) { modelFacts += '<div class="callout">' + esc(m.note) + '</div>'; }

    var targetsNote = mayWrite.length
      ? '<div class="meta">写入只会动：' + esc(mayWrite.map(function (c) { return c.label; }).join('、')) +
        '（只改受管字段，写前留时间戳备份）</div>'
      : '';
    var guideNote = onlyGuide.length
      ? '<div class="callout">另有 ' + onlyGuide.length + ' 处需要你<b>自己在它的界面里填</b>：' +
        esc(onlyGuide.map(function (c) { return c.label; }).join('、')) + '。那种地方本工具不碰。</div>'
      : '';
    var manualHtml = manualBlockHtml(d, id);
    var pendingHtml = keyHelpBlock(d, ctx);

    if (guidanceOnly) {
      // 只给值：渠道与模型仍然可选（选完值会跟着变），但没有"写入"按钮
      return '<div class="card">' +
        (ctx.providers.length ? '' : '<div class="meta">正在读取渠道列表…</div>') +
        '<div class="opts">' +
        '<label class="chk">渠道：<select id="cfgProvider-' + esc(id) + '">' + provOpts + '</select></label>' +
        '<label class="chk">模型：<input id="cfgModel-' + esc(id) + '" type="text" list="cfgModelList-' + esc(id) +
          '" value="' + esc(ctx.st.model) + '" size="26" spellcheck="false">' +
          '<datalist id="cfgModelList-' + esc(id) + '">' + modelOpts + '</datalist></label>' +
        '</div>' +
        (ctx.models.length
          ? '<div class="meta">这个渠道提供：' + esc(ctx.models.join('、')) + '（也可以手输别的模型名）</div>'
          : '<div class="meta">这个渠道没登记模型清单，模型名自己填。</div>') +
        '<div class="meta" style="margin-top:8px"><b>要填到 ' + esc(d.name) + ' 里的值：</b></div>' +
        '<table class="tbl"><tbody>' +
        '<tr><td>Base URL</td><td class="mono">' + esc((ctx.sel && (ctx.sel.anthropicBaseUrl || ctx.sel.openaiBaseUrl)) || '（这个渠道没登记）') +
          '</td><td><button class="tiny" data-copy="' + esc((ctx.sel && (ctx.sel.anthropicBaseUrl || ctx.sel.openaiBaseUrl)) || '') + '">复制</button></td></tr>' +
        '<tr><td>模型</td><td class="mono">' + esc(ctx.st.model) + '</td>' +
          '<td><button class="tiny" data-copy="' + esc(ctx.st.model) + '">复制</button></td></tr>' +
        '<tr><td>API Key</td><td class="meta">用你自己那把（存在变量 ' + esc(ctx.st.tokenEnv || '你的变量名') + ' 里）</td><td></td></tr>' +
        '</tbody></table>' +
        modelFacts +
        guideNote +
        '<div class="callout">本工具<b>不写</b>它的配置文件：格式是它自己的私有结构，盲写风险太大。' +
        '上面这几个值你在它自己的界面里填一次就行。</div>' +
        '</div>';
    }

    return '<div class="card">' +
      (ctx.providers.length ? '' : '<div class="meta">正在读取渠道列表…</div>') +
      '<div class="opts">' +
      '<label class="chk">渠道：<select id="cfgProvider-' + esc(id) + '">' + provOpts + '</select></label>' +
      '<label class="chk">存 key 的变量名：<input id="cfgEnv-' + esc(id) + '" type="text" value="' +
        esc(ctx.st.tokenEnv) + '" size="22" spellcheck="false"></label>' +
      '<label class="chk">模型：<input id="cfgModel-' + esc(id) + '" type="text" list="cfgModelList-' + esc(id) +
        '" value="' + esc(ctx.st.model) + '" size="26" spellcheck="false">' +
        '<datalist id="cfgModelList-' + esc(id) + '">' + modelOpts + '</datalist></label>' +
      '</div>' +
      (ctx.models.length
        ? '<div class="meta">这个渠道提供：' + esc(ctx.models.join('、')) + '（也可以直接手输别的模型名）</div>'
        : '<div class="meta">这个渠道没登记模型清单，模型名自己填。</div>') +
      modelFacts +
      '<div class="acts" style="margin-top:10px">' +
      '<button class="primary" id="cfgWrite-' + esc(id) + '">写入这个工具的配置</button>' +
      (m.writable ? '' : '<button class="tiny" data-copy="' + esc(ctx.st.model || '') + '">复制模型名</button>') +
      '<span class="note">只写这一个工具。点下去会先弹确认框，里面是服务端给出的命令原文。</span>' +
      '</div>' +
      '<div class="callout"><b>key 怎么填：</b>打开 <code>%USERPROFILE%\\.claude\\settings.json</code>，把 <code>ANTHROPIC_AUTH_TOKEN</code> 那一行里的 <code>&lt;在这里粘贴你的 API Key&gt;</code> 换成你的真 key，保存，然后重开 Claude Code。</div>' +
      pendingHtml + targetsNote + guideNote +
      '<div class="callout">这里填的是<b>变量名</b>，不是 key。key 的值留在你自己的环境变量里，' +
      '本工具只在写配置那一刻读一次。</div>' +
      '<details class="howto"><summary>key 到底怎么放进环境变量？（三种办法）</summary>' +
      '<div class="howto-body">' +
      '<p><b>本工具不替你存 key。</b>上面那个输入框填的是 key 的<b>名字</b>，不是 key。' +
      '真正的值要你自己放进环境变量，三种办法挑一个：</p>' +
      '<ol>' +
      '<li><b>临时试一下</b>（只对这个窗口有效）<br>' +
      '<code>$env:' + esc(ctx.st.tokenEnv || 'PROVIDER_KEY') + ' = "sk-你的key"</code><br>' +
      '关掉窗口就没了。适合先确认 key 是通的。</li>' +
      '<li><b>长期生效</b>（推荐）<br>' +
      '<code>setx ' + esc(ctx.st.tokenEnv || 'PROVIDER_KEY') + ' "sk-你的key"</code><br>' +
      '写进你的用户环境变量，<b>之后新开的</b>窗口都能读到。<b>已经开着的</b>窗口读不到 —— ' +
      '不过本工具每次检测、每次写入之前都会把注册表里最新的环境同步进自己的进程，所以在这个页面直接点「写入」就行。</li>' +
      '<li><b>用图形界面改</b><br>按 Win 键搜「环境变量」→ 打开「编辑账户的环境变量」→ 新建 → ' +
      '变量名填 <code>' + esc(ctx.st.tokenEnv || 'PROVIDER_KEY') + '</code>，值填你的 key。</li>' +
      '</ol>' +
      '<p class="note">为什么卡这么严：key 只存在你自己的机器上、只在你自己的环境变量里。' +
      '本工具既不上传也不保存，连「帮你写进环境变量」都不做 —— 那一步就要经手明文 key 了。' +
      '另外：别把 key 贴进任何网页，包括这个页面。</p>' +
      '</div></details>' +
      manualHtml +
      '</div>';
  }


  // 自动写入为主之后，官方那套「手填」说明仍然有用（有哪些变量、官方文档在哪）。
  // 收进折叠块：默认不占地，想核对或者想手填的人点开就有。
  function manualBlockHtml(d, id) {
    var integ = integrationFor(id);
    if (!integ) { return ''; }
    var env = integ.env || [];
    var steps = integ.steps || [];
    if (!env.length && !steps.length) { return ''; }
    var inner = '';
    if (integ.docUrl) {
      inner += '<div class="meta">依据：<a href="' + esc(integ.docUrl) + '" target="_blank" rel="noreferrer">' +
        esc(d.name) + ' 官方接入说明' + (integ.docSection ? ' · ' + esc(integ.docSection) : '') + '</a>' +
        (integ.checkedAt ? '（核对于 ' + esc(integ.checkedAt) + '）' : '') + '</div>';
    }
    if (env.length) {
      var lines = env.map(function (e) { return '$env:' + e.name + '="' + e.value + '"'; }).join('\n');
      var rows = env.map(function (e) {
        return '<tr><td class="mono">' + esc(e.name) + '</td>' +
          '<td class="mono">' + esc(e.value) + '</td>' +
          '<td><button class="tiny" data-copy="' + esc(e.value) + '">复制值</button></td></tr>';
      }).join('');
      inner += '<pre class="cmdbig">' + esc(lines) + '</pre>' +
        '<div class="acts"><button class="tiny" data-copy="' + esc(lines) + '">复制全部 ' + env.length + ' 行</button></div>' +
        '<table class="tbl"><thead><tr><th>变量</th><th>值</th><th></th></tr></thead><tbody>' + rows + '</tbody></table>';
    }
    if (steps.length) { inner += stepsList(steps); }
    if (integ.note) { inner += '<div class="callout">' + esc(integ.note) + '</div>'; }
    return '<details class="howto"><summary>也可以照 ' + esc(d.name) + ' 官方说明手动填（' +
      (env.length ? env.length + ' 个环境变量' : '几个步骤') + '）</summary>' +
      '<div class="howto-body">' + inner + '</div></details>';
  }
  // 路径一律用模版写法（%USERPROFILE%\...），显示和复制都不带本机用户名。
  // 复制出去的命令是给 PowerShell 用的，所以再把 %VAR% 换成 $env:VAR。
  function psPathOf(tpl) {
    var s = String(tpl || '');
    s = s.replace(/%USERPROFILE%/ig, function () { return '$env:USERPROFILE'; });
    s = s.replace(/%LOCALAPPDATA%/ig, function () { return '$env:LOCALAPPDATA'; });
    s = s.replace(/%APPDATA%/ig, function () { return '$env:APPDATA'; });
    return s;
  }

  // key 还停在占位符时，把「改哪个文件、改哪一行、改完做什么」直接写在界面里。
  // 判定来自服务端（/api/tool/<id> 的 configTargets[].pending），界面不自己猜。
  function pendingKeyCallout(d, ctx) {
    var ts = d.configTargets || [];
    var hits = [];
    for (var i = 0; i < ts.length; i++) {
      var pend = ts[i].pending || [];
      for (var k = 0; k < pend.length; k++) { hits.push({ t: ts[i], item: pend[k] }); }
    }
    if (!hits.length) { return ''; }
    var names = hits.map(function (h) { return h.item.name; }).join('、');
    var t0 = hits[0].t;
    var fileTpl = t0.path || '';
    var openCmd = 'notepad "' + psPathOf(fileTpl) + '"';
    var envName = (ctx && ctx.st && ctx.st.tokenEnv) ? ctx.st.tokenEnv : 'DEEPSEEK_API_KEY';
    var setxCmd = 'setx ' + envName + ' "sk-你的key"';
    return '<div class="callout warn">' +
      '<b>还有 ' + hits.length + ' 个占位符没填（' + esc(names) + '）—— 现在启动会认证失败（401）。</b>' +
      '<div class="meta">两种填法，选一种就行：</div>' +
      '<ol class="steps">' +
      '<li><span class="stepdo">直接改文件（最快）</span>' +
      '<div class="meta">用记事本打开 <code>' + esc(fileTpl) + '</code>，把 <code>' + esc(hits[0].item.placeholder) + '</code> 换成你的真 key，保存；然后重开 Claude Code。</div>' +
      '<div class="mkcmd">' + esc(openCmd) + '</div>' +
      '<div class="acts"><button class="tiny" data-copy="' + esc(openCmd) + '">复制这条命令</button>' +
      '<button class="tiny" data-copy="' + esc(fileTpl) + '">复制路径</button></div></li>' +
      '<li><span class="stepdo">先放进环境变量，再让本工具写</span>' +
      '<div class="meta">在 PowerShell 里执行下面这条，然后点上面的「写入这个工具的配置」——这样 key 不用贴进这个页面。</div>' +
      '<div class="mkcmd">' + esc(setxCmd) + '</div>' +
      '<div class="acts"><button class="tiny" data-copy="' + esc(setxCmd) + '">复制这条命令</button></div></li>' +
      '</ol>' +
      '<div class="meta">两条路走一条就够：直接改了文件，就不必再点写入。</div>' +
      '</div>';
  }
  // 界面上不出现本机用户名：把绝对的用户目录改写成 %USERPROFILE% / %LOCALAPPDATA% / %APPDATA%。
  // 只用于「给人看」的文本；按钮里 data-copy 的值仍是真实路径，否则粘出去的命令跑不了。
  function maskUserPath(s) {
    var t = String(s == null ? '' : s);
    t = t.replace(/([A-Za-z]:\\Users\\)[^\\]+\\AppData\\Local\\/g, function () { return '%LOCALAPPDATA%\\'; });
    t = t.replace(/([A-Za-z]:\\Users\\)[^\\]+\\AppData\\Roaming\\/g, function () { return '%APPDATA%\\'; });
    t = t.replace(/([A-Za-z]:\\Users\\)[^\\]+\\/g, function () { return '%USERPROFILE%\\'; });
    return t;
  }

  // 常驻说明：key 存在哪个文件的哪个字段、以后想换怎么改。
  // 没填好时交给 pendingKeyCallout 那条警告，这里只给「已经填好」的折叠说明。
  function keyHelpBlock(d, ctx) {
    var warnHtml = pendingKeyCallout(d, ctx);
    if (warnHtml) { return warnHtml; }
    var ts = d.configTargets || [];
    var target = null;
    for (var i = 0; i < ts.length; i++) {
      var mk = ts[i].managedKeys || [];
      if (ts[i].kind !== 'guidance' && mk.length) { target = ts[i]; break; }
    }
    if (!target) { return ''; }
    var fileTpl = target.path || '';
    var openCmd = 'notepad "' + psPathOf(fileTpl) + '"';
    var mk2 = target.managedKeys || [];
    var tokenName = '';
    for (var k = 0; k < mk2.length; k++) { if (/(TOKEN|KEY)/i.test(mk2[k])) { tokenName = mk2[k]; break; } }
    var envName = (ctx && ctx.st && ctx.st.tokenEnv) ? ctx.st.tokenEnv : 'DEEPSEEK_API_KEY';
    var setxCmd = 'setx ' + envName + ' "sk-你的key"';
    var total = (target.managedKeys || []).length;
    var done = Number(target.filled || 0);
    var stateLine;
    if (!target.exists) {
      stateLine = '<div class="meta">状态：这个配置文件还没生成 —— 点上面的「写入这个工具的配置」就会建出来（只写 base_url 与模型名；key 不写，你自己填）。</div>';
    } else if (done >= total) {
      stateLine = '<div class="meta">状态：<code>' + esc(fileTpl) + '</code> 里的 ' + total + ' 个受管字段都已填好（含 key）。</div>';
    } else {
      stateLine = '<div class="meta">状态：文件在，但受管字段只填了 ' + done + ' / ' + total + ' —— 缺的那个多半就是 key。</div>';
    }
    return '<details class="howto"><summary>key 放在哪、以后想换怎么改</summary>' +
      '<div class="howto-body">' +
      '<div class="meta">文件：<code>' + esc(fileTpl) + '</code> ' +
      '<button class="tiny" data-copy="' + esc(fileTpl) + '">复制路径</button></div>' +
      stateLine +
      '<div class="meta" style="margin-top:8px"><b>想换 key 的话，两种办法选一种：</b></div>' +
      '<ol class="steps">' +
      '<li><span class="stepdo">直接改文件</span>' +
      '<div class="meta">用记事本打开上面那个文件，把 <code>' + esc(tokenName || 'key') + '</code> 那一行的值换成新 key，保存，重开 Claude Code。</div>' +
      '<div class="mkcmd">' + esc(openCmd) + '</div>' +
      '<div class="acts"><button class="tiny" data-copy="' + esc(openCmd) + '">复制这条命令</button></div></li>' +
      '<li><span class="stepdo">先放进环境变量，再让本工具写</span>' +
      '<div class="meta">执行下面这条，然后点上面的「写入这个工具的配置」——key 不用贴进这个页面。</div>' +
      '<div class="mkcmd">' + esc(setxCmd) + '</div>' +
      '<div class="acts"><button class="tiny" data-copy="' + esc(setxCmd) + '">复制这条命令</button></div></li>' +
      '</ol>' +
      '<div class="meta">注：界面上的路径一律写成 %USERPROFILE% 这类模版，不显示你的用户名。</div>' +
      '</div></details>';
  }
  function bindCfgPanel(d) {
    var id = d.id;
    var ctx = cfgState(id);
    var sp = $('cfgProvider-' + id);
    if (sp) {
      sp.onchange = function () {
        ctx.st.provider = this.value;
        ctx.st.tokenEnv = tokenEnvOf(this.value);
        ctx.st.model = '';
        render();
      };
    }
    var se = $('cfgEnv-' + id);
    if (se) { se.onchange = function () { ctx.st.tokenEnv = this.value; }; }
    var sm = $('cfgModel-' + id);
    if (sm) { sm.onchange = function () { ctx.st.model = this.value; }; }
    var bw = $('cfgWrite-' + id);
    if (bw) {
      bw.onclick = function () {
        var st = ctx.st;
        if (!st.provider) { toast('先选一个渠道'); return; }
        act('config-write', {
          providerId: st.provider,
          authTokenEnvVar: st.tokenEnv,
          model: st.model,
          toolIds: [id]
        });
      };
    }
  }
  /*
   * 操作步骤：内容全部来自 tools.json 的 guide.steps（每个工具不一样 ——
   * Claude Code 装完就能用、cc-switch 要在它界面里加供应商、dsh 要先起网页界面）。
   * 这里只做三件事：按顺序渲染、把 {tokenEnv}/{model} 换成当前值、标出哪一步该谁做。
   */
  function guideStepState(d, check) {
    if (!check) { return { cls: '', text: '' }; }
    if (check === 'installed') {
      return d.installed ? { cls: 'ok', text: '已完成' } : { cls: 'warn', text: '该你了' };
    }
    if (check === 'configured') {
      var ts = d.configTargets || [];
      if (!ts.length) { return { cls: '', text: '' }; }
      var exists = ts.filter(function (c) { return c.exists; }).length;
      if (exists > 0) { return { cls: 'ok', text: '已完成' }; }
      return { cls: 'warn', text: '该你了' };
    }
    if (check === 'model') {
      var cur = (d.models && d.models.current) || '';
      if (cur) { return { cls: 'ok', text: '当前：' + cur }; }
      return { cls: '', text: '需要你确认' };
    }
    if (check === 'launch') {
      return d.installed ? { cls: '', text: '' } : { cls: '', text: '装上之后才能启动' };
    }
    return { cls: '', text: '' };
  }


  // 旧的 #/config 地址：配置已经搬进各智能体页，给一句解释而不是白屏
  function renderConfigMoved() {
    // 刻意**不**在这里请求 /api/overview：那个接口要做网络探测，慢；
    // 而服务端是单线程顺序 accept，多一个慢请求会把后面所有请求一起堵住。
    // 已经加载过就直接列出来，没有就只给一句"从顶栏进去"。
    var all = (S.overview && S.overview.tools) || [];
    var links = all.filter(function (t) { return t.role !== 'provider-manager'; }).map(function (t) {
      return '<li><a href="#/tool/' + esc(t.id) + '">' + esc(t.name) + '</a></li>';
    }).join('');
    $('app').innerHTML =
      '<div class="bar"><a href="#/">← 回首页</a></div>' +
      '<section><h2>配置搬走了</h2><div class="card">' +
      '<div class="meta">不再有一个"全局配置页"：每个智能体认的字段、能用的模型、能不能真写文件，全都不一样，' +
      '所以配置现在写在每个智能体自己的页面上。</div>' +
      '<div class="callout">去对应智能体的页面，在「渠道与模型」里选渠道、填变量名、选模型，' +
      '再点「写入这个工具的配置」。</div>' +
      (links ? '<div class="meta">从这里进去：</div><ul>' + links + '</ul>' : '<div class="meta">从顶栏选一个智能体进去。</div>') +
      '</div></section>';
  }
  // 分段式排版用的东西（只有 guide.steps 里每步都写了 section 的工具才走这条路）
  var STEP_NO = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];

  function stepFill(d, s) {
    var ctx = cfgState(d.id);
    return String(s == null ? '' : s)
      .replace(/\{tokenEnv\}/g, ctx.st.tokenEnv || '你的变量名')
      .replace(/\{model\}/g, ctx.st.model || '你选的模型')
      .replace(/\{toolName\}/g, d.name || '');
  }

  function useStepLayout(d) {
    var steps = (d.guide && d.guide.steps) || [];
    if (!steps.length) { return false; }
    for (var i = 0; i < steps.length; i++) { if (!steps[i].section) { return false; } }
    return true;
  }

  // 标题下的一行元信息：把原来的「状态」整节压成一行，省掉一节的空间
  function toolMetaLine(d) {
    var bits = [];
    bits.push('命令 ' + mono(maskUserPath(d.executable) || '（未找到）'));
    bits.push('副本 ' + (d.installCount || 0));
    bits.push('残留 ' + (d.artifacts && d.artifacts.length ? d.artifacts.length + ' 组' : '无'));
    var line = '<div class="meta toolstat">' + bits.join(' · ') + '</div>';
    if (d.notes) { line += '<div class="meta">' + esc(d.notes) + '</div>'; }
    return line;
  }

  // 维护区：不编号、折叠在最底。卸载是危险操作，不该混在日常步骤里。
  function maintSection(d, id, opts) {
    var ops = '';
    if (opts.canArtifacts) {
      ops += '<button data-act="tool-artifacts" data-target="' + esc(id) + '">清理安装残留</button>';
    }
    if (opts.canUninstall) {
      ops += '<button class="danger" data-act="tool-uninstall" data-target="' + esc(id) + '">卸载</button>';
    }
    var uninstallNote = opts.canUninstall
      ? '<div class="callout" style="margin-top:10px">卸载是<b>只搬不删</b>：安装本体、残留文件和它加进 PATH 的条目' +
        '都会挪到备份区并写进日志，随时可以还原。' +
        '<div class="opts"><label class="chk"><input type="checkbox" id="opt-dropcfg">' +
        '同时移除这个工具的用户配置（<span class="failText">这一步不是搬走，是真的删</span>）</label></div></div>'
      : (d.uninstallReason
        ? '<div class="callout" style="margin-top:10px"><b>这个工具不由本工具卸载。</b>' + esc(d.uninstallReason) + '</div>'
        : '');
    var body = '<div class="card"><div class="acts">' + (ops || '<span class="note">没有可用的维护操作</span>') +
      '</div>' + uninstallNote + '</div>';
    body += '<div class="meta" style="margin-top:10px">安装位置</div>' + installsHtml(d);
    body += '<div class="meta" style="margin-top:10px">这个工具自己的配置</div><div class="grid">' + cfgHtml(d) + '</div>';
    return '<section class="maint"><details><summary>维护与细节（安装位置 / 配置文件明细 / 清理残留 / 卸载）</summary>' +
      body + '</details></section>';
  }

  /*
   * 有些渠道对某个工具给了**官方接入说明**（例如 DeepSeek 对 Claude Code 的 9 个环境变量）。
   * 那种情况下本节直接照官方原文给步骤，本工具不写任何文件 ——
   * 因为官方要求的字段我们并没有全部登记，自动写出半套配置比不写更糟。
   */
  function integrationFor(toolId) {
    var ctx = cfgState(toolId);
    if (!ctx.sel || !ctx.sel.integrations) { return null; }
    return ctx.sel.integrations[toolId] || null;
  }

  // 一份「do / hint / code」写成的步骤 → 有序列表。
  // 官方接入说明和 cc-switch 教程用的是同一个渲染器：文案一律来自配置，界面不拼句子。
  function stepsList(steps) {
    return '<ol class="steps">' + (steps || []).map(function (s) {
      var code = s.code
        ? '<div class="cmd">' + esc(s.code) + '</div>' +
          '<div class="acts"><button class="tiny" data-copy="' + esc(s.code) + '">复制</button></div>'
        : '';
      return '<li><span class="stepdo">' + esc(s.do) + '</span>' +
        (s.hint ? '<div class="meta">' + esc(s.hint) + '</div>' : '') + code + '</li>';
    }).join('') + '</ol>';
  }

  function integrationCardBody(d, integ) {
    // 教程是按渠道给的，所以选择器要留着：换渠道就换教程
    var ctx = cfgState(d.id);
    // 教程模式不再走渠道卡片，所以这里要自己触发一次渠道列表加载
    if (!ctx.providers.length) { ensureProviders(); }
    var provOpts = ctx.providers.map(function (p) {
      return '<option value="' + esc(p.id) + '"' + (ctx.sel && p.id === ctx.sel.id ? ' selected' : '') + '>' + esc(p.name) + '</option>';
    }).join('');
    var selHtml = '<div class="opts"><label class="chk">渠道：<select id="cfgProvider-' + esc(d.id) + '">' +
      provOpts + '</select></label></div>';

    // 渠道自己的入口：注册账号 / 创建 API Key（登记了几个就显示几个，两种卡片都带）
    var entryLinks = [];
    if (ctx.sel && ctx.sel.registerUrl) {
      entryLinks.push('<a href="' + esc(ctx.sel.registerUrl) + '" target="_blank" rel="noreferrer">注册账号</a>');
    }
    if (ctx.sel && ctx.sel.keyUrl) {
      entryLinks.push('<a href="' + esc(ctx.sel.keyUrl) + '" target="_blank" rel="noreferrer">创建 API Key</a>');
    }
    var entryHtml = entryLinks.length
      ? '<div class="meta">' + esc((ctx.sel && ctx.sel.name) || '') + '：' + entryLinks.join(' · ') + '</div>'
      : '';

    var env = (integ && integ.env) ? integ.env : [];
    var steps = (integ && integ.steps) ? integ.steps : [];

    // 没登记官方说明的渠道：只给它的文档网址，不给步骤 ——
    // 与其自己编一套"大概能成"的步骤，不如让用户直接看官方原文。
    if (!env.length && !steps.length) {
      var pDoc = (ctx.sel && ctx.sel.docsUrl) ? ctx.sel.docsUrl : '';
      return '<div class="card">' + selHtml +
        '<div class="meta">这个渠道还没登记 ' + esc(d.name) + ' 的官方接入说明。</div>' +
        (pDoc
          ? '<div class="meta">请看该渠道的官方文档：<a href="' + esc(pDoc) + '" target="_blank" rel="noreferrer">' + esc(pDoc) + '</a></div>'
          : '<div class="meta">这个渠道也没登记文档地址。</div>') +
        entryHtml +
        '</div>';
    }

    var head = '<div class="card">' + selHtml +
      '<div class="meta">依据：<a href="' + esc(integ.docUrl) + '" target="_blank" rel="noreferrer">' +
        esc(d.name) + ' 官方接入说明' + (integ.docSection ? ' · ' + esc(integ.docSection) : '') + '</a>' +
        (integ.checkedAt ? '（核对于 ' + esc(integ.checkedAt) + '）' : '') + '</div>' +
      entryHtml;

    var noteHtml = integ.note ? '<div class="callout">' + esc(integ.note) + '</div>' : '';

    // 形式一：一堆环境变量（Claude Code 那种，官方给的就是 $env: 多行）
    if (env.length) {
      var lines = env.map(function (e) {
        return '$env:' + e.name + '="' + e.value + '"';
      }).join('\n');
      var rows = env.map(function (e) {
        return '<tr><td class="mono">' + esc(e.name) + '</td>' +
          '<td class="mono">' + esc(e.value) + '</td>' +
          '<td><button class="tiny" data-copy="' + esc(e.value) + '">复制值</button></td></tr>';
      }).join('');
      return head +
        '<div class="meta">在 PowerShell 里执行下面这些（key 换成你自己的）：</div>' +
        '<pre class="cmdbig">' + esc(lines) + '</pre>' +
        '<div class="acts"><button class="primary" data-copy="' + esc(lines) + '">复制全部 ' + env.length + ' 行</button>' +
        '<span class="note">只在当前这个 PowerShell 窗口有效；想长期生效就改用 setx（形如 setx 名字 "值"）。</span></div>' +
        '<details><summary>逐个变量看（' + env.length + ' 个）</summary>' +
        '<table class="tbl"><thead><tr><th>变量</th><th>值</th><th></th></tr></thead><tbody>' + rows + '</tbody></table>' +
        '</details>' +
        noteHtml +
        '</div>';
    }

    // 形式二：在工具自己的界面里点几步（OpenCode 那种 /connect 流程）
    return head +
      stepsList(steps) +
      noteHtml +
      '</div>';
  }

  /*
   * 有些工具的操作不在我们这儿做：cc-switch 要把供应商加在它自己界面里，
   * Gemini CLI 的渠道也得靠 cc-switch 去写。这一节就给"在那个工具里怎么点"的步骤 + 要填的值，
   * 本工具不写它们的任何文件。文案（标题 / 两个小标题）都可以在配置里改。
   */
  function inAppCardBody(d) {
    var sv = d.inApp || {};
    var name = sv.name || '那个工具';
    var valuesLabel = sv.valuesLabel || ('要填进 ' + name + ' 里的值：');
    var stepsLabel = sv.stepsLabel || ('在 ' + name + ' 里怎么操作：');
    var ctx = cfgState(d.id);
    if (!ctx.providers.length) { ensureProviders(); }
    var provOpts = ctx.providers.map(function (p) {
      return '<option value="' + esc(p.id) + '"' + (ctx.sel && p.id === ctx.sel.id ? ' selected' : '') + '>' + esc(p.name) + '</option>';
    }).join('');
    var modelOpts = ctx.models.map(function (x) { return '<option value="' + esc(x) + '"></option>'; }).join('');
    var baseUrl = (ctx.sel && (ctx.sel.openaiBaseUrl || ctx.sel.anthropicBaseUrl)) || '';

    var showValues = (sv.showValues !== false);
    var rows = [[
      '名称', (ctx.sel && ctx.sel.name) || ''
    ], [
      'Base URL', baseUrl
    ], [
      '模型', ctx.st.model || ''
    ]].map(function (r) {
      return '<tr><td>' + esc(r[0]) + '</td><td class="mono">' + esc(r[1] || '（还没选渠道/模型）') + '</td>' +
        '<td><button class="tiny" data-copy="' + esc(r[1] || '') + '">复制</button></td></tr>';
    }).join('');

    // 有的工具那一步跟渠道无关（例如 python 只是配 pip 镜像）：showValues=false 时
    // 不给渠道选择器、也不给值表，只给步骤 —— 否则会凭空出现一个"渠道 ▾"让人莫名其妙。
    var valuesBlock = showValues
      ? ('<div class="opts">' +
        '<label class="chk">渠道：<select id="cfgProvider-' + esc(d.id) + '">' + provOpts + '</select></label>' +
        '<label class="chk">模型：<input id="cfgModel-' + esc(d.id) + '" type="text" list="cfgModelList-' + esc(d.id) +
          '" value="' + esc(ctx.st.model) + '" size="26" spellcheck="false">' +
          '<datalist id="cfgModelList-' + esc(d.id) + '">' + modelOpts + '</datalist></label>' +
        '</div>' +
        (ctx.models.length
          ? '<div class="meta">这个渠道提供：' + esc(ctx.models.join('、')) + '（也可以手输别的模型名）</div>'
          : '<div class="meta">这个渠道没登记模型清单，模型名自己填。</div>') +
        '<div class="meta" style="margin-top:8px"><b>' + esc(valuesLabel) + '</b></div>' +
        '<table class="tbl"><tbody>' + rows +
        '<tr><td>API Key</td><td class="meta">用你自己那把（本工具不保存、不经手）</td><td></td></tr>' +
        '</tbody></table>')
      : '';
    return '<div class="card">' +
      valuesBlock +
      '<div class="meta" style="margin-top:10px"><b>' + esc(stepsLabel) + '</b></div>' +
      stepsList(sv.steps) +
      (sv.note ? '<div class="callout">' + esc(sv.note) + '</div>' : '') +
      (sv.docUrl
        ? '<div class="meta">' + esc(name) + ' 自己的说明：<a href="' + esc(sv.docUrl) + '" target="_blank" rel="noreferrer">' +
          esc(sv.docUrl) + '</a></div>'
        : '') +
      '</div>';
  }

  // 一段 = 一个编号标题 + 一句提示 + 真正的控件
  /*
   * 常用第三方库：只检测装没装（服务端跑一次解释器，只读），给出可复制的安装命令。
   * 本工具不替你 pip install —— 那会改它的 site-packages，是与"写别人的配置"同类的越界。
   */
  function packagesCardBody(d) {
    var list = d.packages || [];
    if (!list.length) {
      return '<div class="card"><div class="meta">这个工具没有登记常用库清单。</div></div>';
    }
    var known = list.filter(function (x) { return !x.unknown; });
    var missing = list.filter(function (x) { return !x.unknown && !x.installed; });
    var done = list.filter(function (x) { return x.installed; }).length;
    var rows = list.map(function (x) {
      var st = x.unknown ? pill('检测不了', 'warn')
        : (x.installed ? pill('已装 ' + (x.version || ''), 'ok') : pill('未安装', ''));
      var cmd = 'pip install ' + x.name;
      return '<tr><td class="mono">' + esc(x.name) + '</td>' +
        '<td>' + esc(x.why || '') + '</td>' +
        '<td>' + st + '</td>' +
        '<td>' + (x.installed ? '' : '<button class="tiny" data-copy="' + esc(cmd) + '">复制安装命令</button>') + '</td></tr>';
    }).join('');
    var allCmd = missing.length ? missing.map(function (x) { return 'pip install ' + x.name; }).join(' && ') : '';
    return '<div class="card">' +
      '<div class="meta">' + list.length + ' 个里已装 <b>' + done + '</b> 个' +
      (known.length < list.length ? '（有 ' + (list.length - known.length) + ' 个检测不了）' : '') + '</div>' +
      '<table class="tbl"><thead><tr><th>库</th><th>用途</th><th>状态</th><th></th></tr></thead><tbody>' + rows + '</tbody></table>' +
      (allCmd
        ? '<div class="acts" style="margin-top:10px"><button class="primary" data-copy="' + esc(allCmd) + '">复制全部未安装的安装命令</button>' +
          '<span class="note">' + missing.length + ' 条命令用 && 串起来，粘进 PowerShell 一次跑完。</span></div>'
        : '<div class="meta" style="margin-top:10px">清单里的库都装好了。</div>') +
      '<div class="callout">本工具<b>只检测</b>：不替你 pip install（那会改它的 site-packages），' +
      '也不改你的 pip 镜像设置 —— 上面「配 pip 镜像」那一段给了改源的命令。</div>' +
      '</div>';
  }

  function stepSection(d, id, s, index, opts) {
    // 配了官方教程的那一段：本工具不写文件，也无从判断你到底设没设环境变量 —— 如实说"需要你确认"
    // 配置段到底是「教你自己填」还是「我帮你写」：只要这个工具存在已验证的写入目标
    // （opts.autoWrite），就优先走写入卡片，官方接入说明在卡片里降级成折叠块。
    // 上一版只挡住了 tutorial 标记、漏了 integration —— DeepSeek 恰好给 Claude Code 登记了
    // 官方接入说明，于是 (tutorial || integration) 仍为真，界面还是那套教程。
    var tutorialCard = (!!opts.inApp) || ((opts.tutorial || !!opts.integration) && !opts.autoWrite);
    var st = (s.section === 'configure' && tutorialCard)
      ? { cls: '', text: '需要你确认' }
      : guideStepState(d, s.check);
    var pillHtml = st.text ? ' ' + pill(st.text, st.cls) : '';
    var no = STEP_NO[index] || String(index + 1);
    var body;
    if (s.section === 'install') {
      body = opts.installHtml;
    } else if (s.section === 'configure') {
      // 这一步要在别的工具界面里做就给那边的操作步骤；这个渠道给了官方接入说明就照它给；
      // 否则走渠道/模型卡片
      body = opts.inApp
        ? inAppCardBody(d)
        : tutorialCard
          ? integrationCardBody(d, opts.integration)
          : cfgCardBody(d, opts.guidanceOnly);
    } else if (s.section === 'launch') {
      body = launchCardBody(d);
    } else if (s.section === 'packages') {
      body = packagesCardBody(d);
    } else {
      body = '<div class="card"><div class="meta">（这个工具登记了未知的段落：' + esc(s.section) + '）</div></div>';
    }
    var title = stepFill(d, s.title || s.do || '');
    var hint = s.hint ? '<div class="meta stephint">' + esc(stepFill(d, s.hint)) + '</div>' : '';
    return '<section class="step"><h2><span class="stepno">' + esc(no) + '</span>' +
      esc(title) + pillHtml + '</h2>' + hint + body + '</section>';
  }

  // 本地模型：这个工具能不能把端点指到本机。
  // 能直连的只给片段与步骤（不代写 —— 这些配置是嵌套的，盲写会把用户已有渠道搞坏）；
  // 不能直连的直接说清为什么，不给假希望。
  function localEndpointSection(d) {
    var e = d.localEndpoint;
    if (!e) { return ''; }
    if (!e.supported) {
      return '<section><h2>本地模型</h2>' +
        '<div class="callout warn">这个工具<b>暂时连不了本地模型</b>：' + esc(e.reason || '') + '</div>' +
        (e.workaround ? '<div class="meta">' + esc(e.workaround) + '</div>' : '') +
        (e.measured ? '<div class="meta">实测状态：' + esc(e.measured) + '</div>' : '') +
        '<div class="meta">想用本地模型：去 <a href="#/local">本地模型</a> 页看你的机器能跑多大。</div></section>';
    }
    var steps = (e.steps || []).map(function (s) { return '<li>' + esc(s) + '</li>'; }).join('');
    return '<section><h2>本地模型（可选）</h2>' +
      '<div class="meta">端点：' + mono('http://127.0.0.1:11434/v1') + '（OpenAI 兼容，本地无 key）' +
      (e.protocol ? ' · 协议：' + mono(e.protocol) : '') + '</div>' +
      (steps ? '<ol>' + steps + '</ol>' : '') +
      '<div class="meta">配置文件：' + mono(maskUserPath(e.configPath || '')) + '</div>' +
      (e.snippet
        ? '<div class="cmd"><pre style="margin:0;white-space:pre-wrap">' + esc(e.snippet) + '</pre></div>' +
          '<div class="acts"><button class="tiny" data-copy="' + esc(e.snippet) + '">复制这段片段</button></div>'
        : '') +
      (e.apiKeyNote ? '<div class="meta">' + esc(e.apiKeyNote) + '</div>' : '') +
      (e.caveat ? '<div class="callout">' + esc(e.caveat) + '</div>' : '') +
      (e.measured ? '<div class="meta">实测状态：' + esc(e.measured) + '</div>' : '') +
      '<div class="meta">接好之后回 <a href="#/local">本地模型</a> 页点一次「自检工具调用」—— 模型不会用工具的话，接上也白搭。</div>' +
      '</section>';
  }
  function renderTool(id) {
    var d = S.detail[id];
    if (!d) { $('app').innerHTML = '<div class="card">读取 ' + esc(id) + ' 的状态中…</div>'; return; }

    var tiers = d.tiers || [];
    var sel = S.tier[id] || d.preferredTier || (tiers[0] && tiers[0].id) || '';
    S.tier[id] = sel;

    var canInstall = (d.actions || []).indexOf('tool-install') >= 0;
    var canUninstall = (d.actions || []).indexOf('tool-uninstall') >= 0;
    var canVerify = (d.actions || []).indexOf('tool-verify') >= 0;
    var canArtifacts = (d.actions || []).indexOf('tool-artifacts') >= 0;

    var head = '<div class="toolhead"><h2>' + esc(d.name) + '</h2>' +
      (d.installed
        ? pill(d.version ? ('已安装 ' + d.version) : '已安装', 'ok')
        : pill('未安装', '')) +
      (d.conflict ? pill('多个副本冲突', 'warn') : '') +
      (d.role === 'provider-manager'
        ? '<span class="meta">配套工具 · 帮你管渠道</span>'
        : (d.role === 'agent' ? '<span class="meta">智能体</span>' : '')) +
      '</div><div class="meta">' + esc(d.vendor || '') +
      (d.homeUrl ? ' · <a href="' + esc(d.homeUrl) + '" target="_blank" rel="noreferrer">官网</a>' : '') +
      '</div>';

    // 多副本冲突：光提示"去清理残留再重装"是句空话 —— 引擎早就有 -ResolveConflicts
    // （保留 PATH 命中的那份，其余挪到备份区），这里把它做成一个按钮，并把
    // "保留哪份 / 挪走哪几份"直接列出来，别让人点了才知道会发生什么。
    var warn = '';
    if (d.conflict) {
      var moves = (d.conflictMove || []).map(function (x) {
        return '<li>' + mono(maskUserPath(x)) + '</li>';
      }).join('');
      warn = '<div class="callout warn"><b>检测到多份安装共存</b>（' + (d.installCount || 0) + ' 份）。' +
        '它们会互相顶掉 —— 新装的命令可能被旧副本挡住。' +
        '<div class="meta" style="margin-top:8px"><b>会保留：</b>' + mono(maskUserPath(d.conflictKeep) || '（PATH 命中的那份）') + '</div>' +
        (moves ? '<div class="meta">会挪到备份区（不删除，可还原）：</div><ul class="issues">' + moves + '</ul>' : '') +
        '<div class="acts" style="margin-top:8px">' +
        '<button class="primary" id="do-conflict">合并多份副本</button>' +
        '<span class="note">规则与命令行一致：保留 PATH 实际命中的那份。</span>' +
        '</div></div>';
    }
    // 只找到 py 启动器、没有 python.exe：多半是装的时候没勾 Add python.exe to PATH
    if (d.onlyLauncher) {
      warn += '<div class="callout warn">只找到 <code>py</code> 启动器，没有找到 <code>python.exe</code>：' +
        '安装时多半没勾「Add python.exe to PATH」。重跑一次安装器选 Repair 即可。</div>';
    }

    // 配套工具要说清它管哪几个。名单来自配置里的 manages，不是写死的文案。
    var managesNote = '';
    if (d.role === 'provider-manager' && (d.manages || []).length) {
      var mnames = (d.manages || []).map(function (id) {
        var hit = ((S.overview && S.overview.tools) || []).filter(function (x) { return x.id === id; })[0];
        return hit ? hit.name : id;
      });
      managesNote = '<div class="callout">它是<b>配套工具，自己不调模型</b>：它管的是「' + esc(mnames.join('、')) +
        '」这几个智能体用哪个渠道。在它的界面里把 Base URL / API Key / 模型填好，由它去写那几个的配置。</div>';
    }

    var installBtn = canInstall
      ? '<button class="primary" id="do-install">' + (d.installed ? '重装' : '安装') + '</button>'
      : (d.manualUrl
        ? '<button class="primary" data-open-url="' + esc(d.manualUrl) + '">打开官网下载页</button>'
        : '');

    // 安装这一段的内部零件，两种排版共用（分段式包在 card 里，经典式直接挂在 section 下）
    var tiersHtml = tiers.length
      ? '<div class="tiers">' + tierHtml(id, tiers, sel) + '</div>'
      : '<div class="card"><div class="meta">配置里没有登记安装方式。</div></div>';
    var installOptsHtml = '<div class="opts">' + installBtn +
      (d.artifacts && d.artifacts.length
        ? '<label class="chk"><input type="checkbox" id="opt-clean"' + (S.clean[id] ? ' checked' : '') + '>' +
          '装之前先清理残留（' + d.artifacts.length + ' 组）</label>'
        : '') +
      (canVerify ? '<button id="do-verify">验证可用性</button>' : '') +
      '</div>';
    var installNoteHtml = canInstall
      ? '<div class="callout">安装 / 重装会按选中的这一层来。<b>重装</b>会先把旧的副本挪到备份区，再装新的。</div>'
      : '<div class="callout">这个工具<b>只能你自己装</b>：点上面的「打开官网下载页」下官方安装器，按它走完；本工具不代跑第三方安装器。装完回这里点「验证可用性」。</div>';
    var installCardHtml = '<div class="card">' + tiersHtml + installOptsHtml + installNoteHtml + '</div>';

    var stepList = (d.guide && d.guide.steps) || [];
    var stepLayout = useStepLayout(d);
    // 这个工具本工具一个字节都不写（全是 guidance 目标）→ 配置那一段只给值不给写入按钮
    var guidanceOnly = (d.configTargets || []).filter(function (c) { return c.kind !== 'guidance'; }).length === 0;
    // 有「已验证 + 非 guidance」的写入目标 → 这个工具的配置本工具真的能自动写。
    // 那就别让 configureMode:tutorial 把写入按钮挡在界外：Claude Code 正是这种 ——
    // writes 里 6 个字段 verified:true，却被 tutorial 标记挡掉，界面上只剩教你自己填。
    var canAutoWrite = (d.configTargets || []).filter(function (c) { return c.kind !== 'guidance' && c.verified; }).length > 0;
    var crumb = '<div class="crumb"><a href="#/">← 返回首页</a></div>';

    // 分段式：页面本身就是步骤。编号由顺序生成，所以每个工具步数不同也不会错乱。
    $('app').innerHTML = crumb + head + toolMetaLine(d) + warn + managesNote +
      stepList.map(function (s, idx) {
        return stepSection(d, id, s, idx, {
          installHtml: installCardHtml,
          guidanceOnly: guidanceOnly,
          integration: integrationFor(id),
          tutorial: (d.configureMode === 'tutorial') && !canAutoWrite,
          autoWrite: canAutoWrite,
          // 这一步要做的事在别的工具界面里（cc-switch 那类）→ 给步骤，不给渠道卡片
          inApp: d.inApp
        });
      }).join('') +
      localEndpointSection(d) +
      maintSection(d, id, { canUninstall: canUninstall, canArtifacts: canArtifacts });

    var ti = $('do-install');
    if (ti) {
      ti.onclick = function () {
        var extra = { targetId: id, tierId: S.tier[id] };
        if ($('opt-clean') && $('opt-clean').checked) { extra.cleanArtifacts = true; }
        act('tool-install', extra);
      };
    }
    var tv = $('do-verify');
    if (tv) { tv.onclick = function () { act('tool-verify', { targetId: id }); }; }
    var oc = $('opt-clean');
    if (oc) { oc.onchange = function () { S.clean[id] = this.checked; }; }
    var od = $('opt-dropcfg');
    if (od) { od.onchange = function () { S.dropCfg = this.checked; }; }
    var cfBtn = $('do-conflict');
    if (cfBtn) { cfBtn.onclick = function () { act('tool-resolve-conflicts', { targetId: id }); }; }
    bindCfgPanel(d);

    var tiersEl = $('app').querySelectorAll('.tier');
    for (var i = 0; i < tiersEl.length; i++) {
      (function (el) {
        el.addEventListener('click', function () {
          S.tier[id] = el.getAttribute('data-tier');
          var all = $('app').querySelectorAll('.tier');
          for (var k = 0; k < all.length; k++) { all[k].classList.remove('sel'); }
          el.classList.add('sel');
        });
      })(tiersEl[i]);
    }
  }

  // ---------------------------------------------------------------- 渠道页
  function renderProviders() {
    if (!S.providers) {
      $('app').innerHTML = '<div class="card">读取渠道列表…</div>';
      getJson('/api/providers').then(function (res) {
        if (res.status !== 200 || !res.body) {
          $('app').innerHTML = '<div class="card"><h3>读不到渠道列表</h3><div class="meta">' +
            esc((res.body && res.body.error) || ('HTTP ' + res.status)) + '</div></div>';
          return;
        }
        S.providers = res.body.providers || [];
        renderProviders();
      });
      return;
    }

    var cards = S.providers.map(function (p) {
      var flags = '';
      if (p.freeQuota) { flags += pill('有免费额度', 'ok'); }
      if (p.needsRealName) { flags += pill('需要实名', 'warn'); }
      if (p.needsCreditCard) { flags += pill('需要信用卡', 'warn'); }
      var links = [];
      if (p.registerUrl) { links.push('<a href="' + esc(p.registerUrl) + '" target="_blank" rel="noreferrer">注册账号</a>'); }
      if (p.keyUrl) { links.push('<a href="' + esc(p.keyUrl) + '" target="_blank" rel="noreferrer">创建 API Key</a>'); }
      if (p.docsUrl) { links.push('<a href="' + esc(p.docsUrl) + '" target="_blank" rel="noreferrer">文档</a>'); }
      var bases = '';
      if (p.anthropicBaseUrl) { bases += '<div class="meta">Anthropic 兼容地址：' + mono(p.anthropicBaseUrl) + '</div>'; }
      if (p.openaiBaseUrl) { bases += '<div class="meta">OpenAI 兼容地址：' + mono(p.openaiBaseUrl) + '</div>'; }
      var models = (p.models && p.models.length)
        ? '<div class="meta">可用模型：' + esc(p.models.join('、')) + '</div>' : '';
      var tags = (p.tags && p.tags.length)
        ? '<div class="meta">' + esc(p.tags.join(' · ')) + '</div>' : '';
      return '<div class="card"><h3>' + esc(p.name) +
        (p.region ? pill(p.region, '') : '') + flags + '</h3>' + tags +
        (p.freeQuota ? '<div class="meta">' + esc(p.freeQuota) + '</div>' : '') +
        bases + models +
        '<div class="acts">' +
        '<span class="note" style="align-self:center">配置在各自智能体页里 —— 顶栏选一个智能体进去</span>' +
        (links.length ? '<span class="note" style="align-self:center">' + links.join(' · ') + '</span>' : '') +
        '</div></div>';
    }).join('');

    $('app').innerHTML =
      '<div class="bar"><span class="note">共 ' + S.providers.length + ' 个渠道。' +
      '配置不在这个页面上 —— 每个智能体的配置都不一样，所以都写在各自智能体的页面里。</span></div>' +
      '<div class="callout"><b>本工具不内置、不代发、不代充任何 API Key。</b>' +
      '这里只给各渠道的注册与创建 Key 的入口链接，key 始终由你自己创建和保管。' +
      '写配置时也只需要填"存 key 的环境变量名"，不需要把 key 交给这个工具。</div>' +
      '<section><h2>渠道</h2><div class="grid">' + (cards || '<div class="card">没有渠道配置</div>') + '</div></section>';
  }

  // ---------------------------------------------------------------- 诊断页
  function loadDiagnostic(then, onFail) {
    getJson('/api/diagnostic').then(function (res) {
      if (res.status === 200 && res.body) { S.diagnostic = res.body; S.diagError = ''; }
      else { S.diagError = '接口返回 ' + res.status + (res.body && res.body.error ? '：' + res.body.error : ''); }
      if (then) { then(); }
    }, function (e) {
      // 请求失败必须说出来。以前这里什么都不做，页面就永远停在"读取诊断报告…"，
      // 看起来像卡死，其实是一次失败被吞掉了。
      S.diagError = '请求失败：' + (e && e.message ? e.message : '未知错误');
      if (onFail) { onFail(e); } else if (then) { then(); }
    });
  }

  function renderDiagnose() {
    if (!S.diagnostic) {
      if (S.diagError) {
        $('app').innerHTML = '<div class="card"><h3>读不到诊断报告</h3>' +
          '<div class="meta">' + esc(S.diagError) + '</div>' +
          '<div class="acts"><button id="retryDiag">重试</button></div></div>';
        $('retryDiag').onclick = function () { S.diagError = ''; S.diagnostic = null; renderDiagnose(); };
        return;
      }
      $('app').innerHTML = '<div class="card">读取诊断报告…</div>';
      loadDiagnostic(renderDiagnose);
      return;
    }
    var d = S.diagnostic;
    var body;
    if (d.exists) {
      body = '<div class="meta">' + esc(d.fileName) + ' · ' + d.bytes + ' 字节 · ' +
        esc(String(d.generatedAt).replace('T', ' ').slice(0, 19)) + '</div>' +
        '<div class="acts" style="margin:8px 0">' +
        '<button id="copyDiag">复制全文</button>' +
        '<button id="reloadDiag">重新读取</button>' +
        '</div>' +
        '<pre id="diagText" class="diagbox"></pre>';
    } else {
      body = '<div class="meta">还没有生成过诊断报告。点下面的按钮生成一份。</div>';
    }

    $('app').innerHTML =
      '<div class="bar"><span class="note">把它贴给别人之前不用自己删东西 —— 报告已经自动脱敏。</span></div>' +
      '<section><h2>生成诊断报告</h2><div class="card">' +
      '<div class="acts"><button class="primary" id="do-diag">生成诊断报告（只读）</button></div>' +
      '<div class="callout">报告汇总环境与安装情况，<b>自动脱敏</b>：不含 API Key、用户名与邮箱。' +
      '生成过程是只读的，不会改动系统。生成完这份页面会自动刷新。</div>' +
      '</div></section>' +
      '<section><h2>最近一份报告</h2><div class="card">' + body + '</div></section>';

    $('do-diag').onclick = function () { act('diagnose'); };
    var cp = $('copyDiag');
    if (cp) {
      $('diagText').textContent = d.text || '';
      cp.onclick = function () {
        if (navigator.clipboard) {
          navigator.clipboard.writeText(d.text || '').then(function () { toast('已复制全文'); },
            function () { toast('复制失败，请手动选中'); });
        } else { toast('浏览器不支持自动复制'); }
      };
    }
    var rl = $('reloadDiag');
    if (rl) { rl.onclick = function () { S.diagnostic = null; renderDiagnose(); }; }
  }

  // ---------------------------------------------------------------- 历史页
  function renderHistory() {
    if (!S.sessions) {
      $('app').innerHTML = '<div class="card">读取历史会话…</div>';
      getJson('/api/sessions').then(function (res) {
        if (res.status !== 200 || !res.body) {
          $('app').innerHTML = '<div class="card"><h3>读不到历史会话</h3><div class="meta">' +
            esc((res.body && res.body.error) || ('HTTP ' + res.status)) + '</div></div>';
          return;
        }
        S.sessions = res.body.sessions || [];
        renderHistory();
      });
      return;
    }

    var rows = S.sessions.map(function (s) {
      var when = String(s.startedAt || '').replace('T', ' ').slice(0, 19);
      var kind = s.dryRun ? pill('演练', '') : pill('真实改动', 'warn');
      var result = pill('成功 ' + s.succeeded, s.succeeded ? 'ok' : '') +
        (s.failed ? pill('失败 ' + s.failed, 'fail') : '') +
        pill('计划 ' + s.planned, '');
      return '<tr><td>' + esc(when) + '</td><td>' + kind + '</td><td>' + result + '</td>' +
        '<td>' + esc((s.kinds || []).join('、')) + '</td>' +
        '<td>' + s.entryCount + '</td>' +
        '<td><button class="tiny" data-restore="' + esc(s.path) + '" data-session="' + esc(s.sessionId || '') + '">还原</button></td></tr>';
    }).join('');

    $('app').innerHTML =
      '<div class="bar"><button id="reloadSess">刷新列表</button>' +
      '<span class="note">每次真的改动都会留一份会话日志，还原就是按它把东西还回去。</span></div>' +
      '<section><h2>会话历史</h2>' +
      (rows
        ? '<table class="tbl"><thead><tr><th>时间</th><th>类型</th><th>结果</th><th>涉及</th><th>条目</th><th></th></tr></thead><tbody>' + rows + '</tbody></table>'
        : '<div class="card"><div class="meta">还没有会话记录。跑一次真的安装或写入之后，这里就会出现记录。</div></div>') +
      '<div class="callout">还原同样遵守<b>只搬不删</b>：' +
      '它按日志把 PATH、安装目录与配置文件恢复到那次改动之前。' +
      '每一条改动型动作都会先弹确认框：框里是服务端给出的、即将真正执行的命令原文。</div>' +
      '</section>';

    $('reloadSess').onclick = function () { S.sessions = null; renderHistory(); };
  }

  function renderNotFound(raw) {
    $('app').innerHTML = '<div class="card"><h3>没有这个页面</h3>' +
      '<div class="meta">地址：' + esc(raw) + '</div>' +
      '<div class="acts"><button onclick="location.hash=\'#/\'">回首页</button></div></div>';
  }

  // ---------------------------------------------------------------- 路由
  function parseQuery(qs) {
    var out = {};
    String(qs || '').split('&').forEach(function (kv) {
      if (!kv) { return; }
      var i = kv.indexOf('=');
      var k = i < 0 ? kv : kv.slice(0, i);
      var v = i < 0 ? '' : kv.slice(i + 1);
      try { out[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' ')); }
      catch (e) { out[k] = v; }
    });
    return out;
  }

  function parse() {
    var h = String(location.hash || '').replace(/^#/, '');
    var q = {};
    var qi = h.indexOf('?');
    if (qi >= 0) { q = parseQuery(h.slice(qi + 1)); h = h.slice(0, qi); }
    if (h === '' || h === '/') { return { page: 'home', q: q }; }
    var m = /^\/tool\/([A-Za-z0-9_\-]+)$/.exec(h);
    if (m) { return { page: 'tool', id: m[1], q: q }; }
    if (/^\/(providers|config|diagnose|history|local)$/.test(h)) { return { page: h.slice(1), q: q }; }
    return { page: 'notfound', raw: h, q: q };
  }

  // ---------------------------------------------------------------- 本地模型页
  // 只读页：硬件判定 + 运行时状态 + 模型档位。
  // 所有结论都由服务层的纯函数算出（含"为什么跑不动"），界面只负责展示 ——
  // 界面自己判一遍就等于有两套判定逻辑，迟早对不上。
  function localVerdictPill(v) {
    if (v === 'ok') { return pill('能跑', 'ok'); }
    if (v === 'slow') { return pill('能跑但慢', 'warn'); }
    if (v === 'no') { return pill('跑不动', 'fail'); }
    return pill('说不准', 'warn');
  }

  // Ollama 的 modified_at 是完整 ISO（带毫秒与时区）。新手不需要看这些，只留到分钟。
  function shortTime(s) {
    var t = String(s || '');
    if (!t) { return ''; }
    return t.replace('T', ' ').slice(0, 16);
  }

  function localCapabilityText(c) {
    if (c === 'agent-ok') { return '能跑智能体'; }
    if (c === 'agent-weak') { return '简单 agent 任务'; }
    return '问答 / 补全';
  }

  // 上下文这一行要同时说清"请求值"和"实测生效值"：
  // 设了但没重启时，环境变量是 32768、实际还是 4096 —— 只说一个就是骗人。
  function contextCell(ol) {
    var req = Number(ol.contextRequested || 0);
    var eff = Number(ol.contextEffective || 0);
    var bits = '';
    if (eff > 0) {
      bits += (eff >= 32768 ? pill('生效 ' + eff, 'ok') : pill('只有 ' + eff, 'warn'));
      bits += '<span class="meta">（加载中的模型实际拿到的）</span>';
    } else {
      bits += '<span class="meta">没有模型在跑，读不到生效值</span>';
    }
    if (req > 0) { bits += '<div class="meta">环境变量 OLLAMA_CONTEXT_LENGTH = ' + esc(String(req)) + '</div>'; }
    if (!ol.contextApplied) {
      bits += '<div class="acts" style="margin-top:6px"><button class="tiny" data-act="local-context">设成 32K</button>' +
        '<span class="note">默认只给 4096，超了会静默截断；设完会重启一次 Ollama 并验证真的生效</span></div>';
    } else {
      bits += '<div class="meta">已经是 32K：智能体不传 num_ctx 也能拿到足够上下文。</div>';
    }
    return bits;
  }
  function renderLocal() {
    $('app').innerHTML = '<div class="card">读取硬件与模型状态中…</div>';
    getJson('/api/local').then(function (res) {
      if (res.status !== 200) {
        $('app').innerHTML = '<div class="card"><h3>读不到本地模型状态</h3><div class="meta">' +
          esc((res.body && res.body.error) || ('HTTP ' + res.status)) + '</div>' +
          '<div class="acts"><a href="#/">回首页</a></div></div>';
        return;
      }
      var d = res.body;
      S.local = d;
      var hw = d.hardware || {};
      var ol = d.ollama || {};

      var gpuRows = (hw.gpus || []).map(function (g) {
        var extra = g.suspicious ? pill('读数可能被截断', 'warn') : '';
        return '<tr><td>' + esc(g.name) + ' ' + extra + '</td><td>' + esc(String(g.vramGB)) + ' GB</td><td>' +
          mono(g.source) + '</td></tr>';
      }).join('');
      if (!gpuRows) { gpuRows = '<tr><td>没有检测到独立显卡</td><td>—</td><td>—</td></tr>'; }

      var ramCell = hw.ramGB > 0
        ? esc(String(hw.ramGB)) + ' GB'
        : '<span class="note">读不到（不影响显存判定，但"能不能退到 CPU 跑"就说不准了）</span>';

      var installedRows = (ol.models || []).map(function (m) {
        var real = 0;
        (d.models || []).forEach(function (x) { if (x.ollamaTag === m.name) { real = x.manifestSizeGB; } });
        var sizeCell = real > 0 ? (esc(String(real)) + ' GB') : (esc(String(m.sizeGB)) + ' GB<span class="note">（清单没读到，用 Ollama 报的数）</span>');
        return '<tr><td>' + mono(m.name) + '</td><td>' + sizeCell + '</td><td>' +
          esc(shortTime(m.modified)) + '</td>' +
          '<td><button class="tiny" data-act="local-endpoint-check" data-target="' + esc(m.name) + '">自检工具调用</button></td></tr>';
      }).join('');
      // 接入矩阵：能直连的给路径，不能直连的说原因 —— 别让用户以为"所有工具都能用本地"
      var nameOf = {};
      ((S.overview && S.overview.tools) || []).forEach(function (t) { nameOf[t.id] = t.name; });
      var endpointRows = (d.endpoints || []).map(function (e) {
        var yn = e.supported ? pill('能', 'ok') : pill('不能', 'fail');
        var how = e.supported
          ? ('改 ' + mono(maskUserPath(e.configPath || '它自己的设置')) + (e.measured ? '<div class="meta">' + esc(e.measured) + '</div>' : ''))
          : esc(e.reason || '');
        return '<tr><td>' + esc(nameOf[e.id] || e.id) + '</td><td>' + yn + '</td><td>' + mono(e.protocol || '') + '</td><td>' + how + '</td></tr>';
      }).join('');

      // 每个档位一个动作：能跑就下、下过就删、跑不动就不给下载按钮。
      // 下载/删除都走 act() → /api/preview → 确认框 → /api/run，不新开任何安全通道。
      var modelCards = (d.models || []).map(function (m) {
        var acts = '';
        if (m.verdict === 'no') {
          acts = '<div class="acts"><button disabled title="' + esc(m.verdictReason) + '">下载</button>' +
            '<span class="note">这台机器跑不动这一档，所以不给下载按钮 —— 别白下 ' + esc(String(m.sizeGB)) + ' GB</span></div>';
        } else if (m.downloaded) {
          acts = '<div class="acts">' +
            '<button data-act="model-remove" data-target="' + esc(m.ollamaTag) + '">删除（释放约 ' + esc(String(m.sizeGB)) + ' GB）</button>' +
            '<span class="note">这一步会真的删文件；删完可以用 ollama pull 装回来，删了什么记在 out\\state\\model-removals.log</span></div>';
        } else {
          acts = '<div class="acts">' +
            '<button class="primary" data-act="model-pull" data-target="' + esc(m.ollamaTag) + '">下载（约 ' + esc(String(m.sizeGB)) + ' GB）</button>' +
            '<span class="note">' + (m.verdict === 'slow' ? '显存不够、会退到 CPU 跑，慢；' : '') +
            '下载前会先算清占多大、磁盘够不够</span></div>';
        }
        return '<div class="card">' +
          '<div class="acts" style="justify-content:space-between;align-items:center">' +
          '<h3 style="margin:0">' + esc(m.name) + '</h3>' +
          '<span>' + localVerdictPill(m.verdict) +
          (m.downloaded ? pill('已下载', 'ok') : '') + '</span></div>' +
          '<div class="meta">' + esc(m.params) + ' / ' + esc(m.quant) + ' / 下载 ' + esc(String(m.sizeGB)) + ' GB' +
          ' / 需要显存 ' + esc(String(m.minVramGB)) + ' GB / 上下文 ' + esc(String(m.context)) +
          ' / ' + esc(m.license) + ' / 能力：' + esc(localCapabilityText(m.capability)) + '</div>' +
          '<div class="meta">模型名：' + mono(m.ollamaTag) + ' <button class="tiny" data-copy="ollama pull ' + esc(m.ollamaTag) + '">复制拉取命令</button></div>' +
          '<div class="callout">' + esc(m.verdictReason) + '</div>' +
          '<div class="meta">' + esc(m.capabilityNote || '') + '</div>' +
          acts +
          '</div>';
      }).join('');

      $('app').innerHTML =
        '<section><h2>本地模型</h2>' +
        '<div class="callout">本地模型跑在你自己机器上：<b>不花钱、数据不出本机、断网也能用</b>；代价是占磁盘、吃显存，能力也比在线 API 弱。' +
        '本地没有 key 这回事 —— 这一页不问你要 key。</div>' +

        '<h3>你的机器</h3>' +
        '<table class="tbl"><thead><tr><th>显卡</th><th>显存</th><th>读数来源</th></tr></thead><tbody>' + gpuRows + '</tbody></table>' +
        '<table class="tbl"><tbody>' +
        '<tr><td>内存</td><td>' + ramCell + '</td></tr>' +
        '<tr><td>磁盘余量</td><td>' + esc(String(hw.diskFreeGB)) + ' GB（按模型目录所在的盘算）</td></tr>' +
        '<tr><td>模型目录</td><td>' + mono(maskUserPath(hw.modelRoot || '')) + '</td></tr>' +
        '</tbody></table>' +

        '<h3>运行时</h3>' +
        (ol.installed
          ? '<table class="tbl"><tbody>' +
            '<tr><td>Ollama</td><td>' + esc(ol.version || '已安装（版本读不到）') +
            (ol.running ? pill('服务在跑', 'ok') : pill('服务没在跑', 'warn')) + '</td></tr>' +
            '<tr><td>安装位置</td><td>' + mono(maskUserPath(ol.installDir || '')) + '</td></tr>' +
            '<tr><td>模型目录</td><td>' + mono(maskUserPath(ol.modelRoot || '')) +
            (ol.isDefaultRoot ? pill('默认位置', 'ok') : pill('被 OLLAMA_MODELS 改过', 'warn')) +
            '<div class="meta">模型文件就在这个目录里；换盘就设 OLLAMA_MODELS。删模型请用下面的「删除」，别手动删目录。</div></td></tr>' +
            '<tr><td>接口</td><td>' + mono(ol.baseUrl || '') + '（OpenAI 兼容，本地无 key）</td></tr>' +
            '<tr><td>默认上下文</td><td>' + contextCell(ol) + '</td></tr>' +
            '<tr><td>已装模型</td><td>' + esc(String(ol.modelsTotalGB || 0)) + ' GB 合计（按清单算实占）</td></tr>' +
            '</tbody></table>' +
            (installedRows
              ? '<table class="tbl"><thead><tr><th>模型</th><th>实占（按清单）</th><th>下载时间</th><th>自检</th></tr></thead><tbody>' + installedRows + '</tbody></table>'
              : '<div class="meta">还没有下过模型。下面每一档都给了拉取命令，挑能跑的那档。</div>')
          : '<div class="callout warn">还没装运行时。先装 Ollama：<a href="#/tool/ollama">Ollama 那一页</a>。' +
            '装之前也能看下面的判定 —— 它会告诉你这台机器适合下多大的模型。</div>') +

        '<div class="callout warn"><b>上下文必须显式调到 32K。</b>' +
        'Ollama 默认只给 4096，超了会<b>静默截断</b>（实测：9630 字符的输入只处理了 2050 个 token，不报任何错）。' +
        '本工具在各处都用 ' + esc(String(d.contextHint || 32768)) + '。</div>' +

        '</section>' +

        '<section><h2>能跑哪一档</h2>' +
        '<div class="meta">判定按「显存 → 内存 → 磁盘」的顺序做：显存够就全量进显卡；显存不够但内存够会退到 CPU（慢）；都不够就是跑不动。' +
        '磁盘按模型体积的 1.5 倍预检。</div>' +
        modelCards +
        '</section>' +

        '<section><h2>接进各智能体</h2>' +
        '<div class="meta">本地端点就是 ' + mono('http://127.0.0.1:11434/v1') + '（OpenAI 兼容，没有 key）。能不能直连，取决于那个工具说不说 OpenAI 这套协议。</div>' +
        '<table class="tbl"><thead><tr><th>工具</th><th>能直连</th><th>协议</th><th>怎么接</th></tr></thead><tbody>' + endpointRows + '</tbody></table>' +
        '<div class="meta">除 Claude Code 外，本工具不代写这些配置 —— 它们是嵌套结构，盲写会把你已有的渠道配置搞坏。各工具自己的页面里给了可复制的片段。</div>' +
        '</section>' +

        '<section><details><summary>本地模型的三个已知坑</summary><p class="note">' +
        '<b>1. 工具调用不一定真会。</b>卡面上写着 tools 不代表它会返回结构化工具调用 —— 实测 deepseek-r1:7b 就不返回，' +
        '只把调用当普通文本吐出来。所以模型目录里的"能力"是按实测标的。' +
        '<br><b>2. 上下文默认只有 4K。</b>见上面那条，必须显式调大。' +
        '<br><b>3. Claude Code 暂时连不了本地。</b>它只说 Anthropic 协议，本地这层是 OpenAI 协议，中间需要一个翻译代理；' +
        '按约定这一版不做，页面上也不会给你假希望。' +
        '</p></details></section>';
    });
  }

  function renderNav(active) {
    var items = ['<a href="#/"' + (active ? '' : ' class="on"') + '>首页</a>'];
    if (S.overview && S.overview.tools) {
      var sepDone = false;
      S.overview.tools.forEach(function (t) {
        // 智能体和配套工具之间放一道分隔线 —— 光看名字看不出 cc-switch / Python 不是智能体
        if (t.role !== 'agent' && !sepDone) {
          items.push('<span class="navsep" title="下面是配套工具：帮你管渠道"></span>');
          sepDone = true;
        }
        var on = (active === t.id) ? ' class="on"' : '';
        items.push('<a href="#/tool/' + esc(t.id) + '"' + on + '>' + esc(t.name) + '</a>');
      });
    }
    items.push('<span class="navsep"></span>');
    [['local', '本地模型'], ['providers', '渠道'], ['diagnose', '诊断'], ['history', '历史']].forEach(function (p) {
      var on = (active === p[0]) ? ' class="on"' : '';
      items.push('<a href="#/' + p[0] + '"' + on + '>' + p[1] + '</a>');
    });
    $('nav').innerHTML = items.join('');
  }

  function render() {
    var r = parse();
    if (r.page === 'tool') {
      renderNav(r.id);
      if (S.detail[r.id]) { renderTool(r.id); }
      else {
        $('app').innerHTML = '<div class="card">读取 ' + esc(r.id) + ' 的状态中…</div>';
        getJson('/api/tool/' + r.id).then(function (res) {
          if (res.status !== 200) {
            $('app').innerHTML = '<div class="card"><h3>读不到这个工具</h3><div class="meta">' +
              esc((res.body && res.body.error) || ('HTTP ' + res.status)) + '</div>' +
              '<div class="acts"><button onclick="location.hash=\'#/\'">回首页</button></div></div>';
            return;
          }
          S.detail[r.id] = res.body;
          renderTool(r.id);
        });
      }
    } else if (r.page === 'home') {
      renderNav('');
      renderHome();
    } else if (r.page === 'providers') {
      renderNav('providers');
      renderProviders();
    } else if (r.page === 'config') {
      renderNav('');
      renderConfigMoved();
    } else if (r.page === 'diagnose') {
      renderNav('diagnose');
      renderDiagnose();
    } else if (r.page === 'history') {
      renderNav('history');
      renderHistory();
    } else if (r.page === 'local') {
      renderNav('local');
      renderLocal();
    } else {
      renderNav('');
      renderNotFound(r.raw);
    }
  }

  // ---------------------------------------------------------------- 事件
  function onDocClick(ev) {
    var b = ev.target.closest ? ev.target.closest('button') : null;
    if (!b) { return; }
    if (b.hasAttribute('data-copy')) {
      var v = b.getAttribute('data-copy');
      if (navigator.clipboard) {
        navigator.clipboard.writeText(v).then(function () { toast('已复制'); },
          function () { toast('复制失败，请手动选中'); });
      } else { toast('浏览器不支持自动复制'); }
      return;
    }
    if (b.hasAttribute('data-open')) {
      location.hash = '#/tool/' + b.getAttribute('data-open');
      return;
    }
    if (b.hasAttribute('data-open-url')) {
      try { window.open(b.getAttribute('data-open-url'), '_blank', 'noreferrer'); }
      catch (e) { toast('打不开，请手动访问'); }
      return;
    }
    if (b.hasAttribute('data-restore')) {
      act('restore', { targetId: b.getAttribute('data-restore') });
      return;
    }
    if (b.hasAttribute('data-launch')) {
      // 启动不走任务队列（见 doLaunch 的注释）
      doLaunch(b.getAttribute('data-launch'),
        b.getAttribute('data-mode') || 'interactive',
        b.getAttribute('data-name') || b.getAttribute('data-launch'));
      return;
    }
    var a = b.getAttribute('data-act');
    if (a) {
      var extra = { targetId: b.getAttribute('data-target') || '' };
      if (a === 'tool-uninstall' && S.dropCfg) { extra.removeUserConfig = true; }
      act(a, extra);
    }
  }

  function loadOverview() {
    return getJson('/api/overview').then(function (res) {
      if (res.status === 200) { S.overview = res.body; }
      if (parse().page === 'home') { render(); } else { renderNav(parse().id); }
    });
  }

  function init() {
    document.addEventListener('click', onDocClick);
    $('modalCancel').onclick = hideModal;
    $('modal').addEventListener('click', function (e) { if (e.target === $('modal')) { hideModal(); } });
    $('modalOk').onclick = function () { if (modalOk) { modalOk(); } };
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { hideModal(); } });

      // 刷新 = 重新扫描全部状态（原来要靠「环境体检」按钮干的活，现在这里就够了）
    $('refresh').onclick = function () {
      S.detail = {};
      loadOverview().then(function () { if (parse().page === 'tool') { render(); } });
    };
    $('logToggle').onclick = function () {
      S.collapsed = !S.collapsed;
      $('logbox').className = 'logbox' + (S.collapsed ? ' collapsed' : '');
      this.textContent = S.collapsed ? '展开' : '收起';
    };

    /*
     * 关闭服务。单文件 exe（winexe）没有控制台，不给个按钮的话用户只能去任务管理器
     * 结束进程；.cmd 那条路虽然有 Ctrl+C，多一个按钮也不亏。
     */
    $('shutdown').onclick = function () {
      showModal('关闭本地服务',
        '<ul><li>会停止本地网页服务并释放端口。</li>' +
        '<li>已经开始的安装动作不会被中断，它会照原样跑完。</li>' +
        '<li>这个页面之后就不能用了，要再打开就重新启动一次。</li></ul>',
        '关闭服务', function () {
          hideModal();
          postJson('/api/shutdown', {}).then(function () {
            document.body.innerHTML =
              '<div style="padding:48px;font:15px/1.8 system-ui,sans-serif;color:#1f2328">' +
              '<h2 style="margin:0 0 8px">服务已关闭</h2>' +
              '<p style="color:#656d76">可以关掉这个页面了。要再用就重新启动一次 LLMKit。</p></div>';
          });
        });
    };

    window.addEventListener('hashchange', render);

    getJson('/api/actions').then(function (res) {
      if (res.status === 200 && res.body && res.body.actions) { S.actions = res.body.actions; }
    }).then(loadOverview).then(function () {
      $('where').textContent = location.host;
      render();
      refreshJobHead();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else { init(); }
})();


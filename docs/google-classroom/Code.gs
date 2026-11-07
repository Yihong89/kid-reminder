/**
 * Google Classroom 数据可达性探针 —— Apps Script 版
 * ==================================================
 *
 * 为什么先给你这个，而不是让你去建 Google Cloud 项目：
 *   Apps Script 用的是 Google 自家的 OAuth 客户端。学校那条「未满 18 岁禁止
 *   使用未配置的第三方 App」的策略，管的是第三方 App，管不到它。所以这是
 *   MOE 这类账号最可能跑通、也最快能验证的一条路——不用建项目、不用下 JSON。
 *
 * 用法：
 *   1. 用孩子的学校账号打开 https://script.google.com  →  新项目
 *   2. 把本文件全部内容粘进 Code.gs（覆盖原有内容）
 *   3. 左下角「项目设置」→ 勾选「在编辑器中显示 appsscript.json」
 *   4. 回到编辑器，打开 appsscript.json，用同目录下 appsscript.json 的内容整个替换
 *   5. 保存 → 顶部函数选 probe → 点「运行」
 *   6. 第一次会弹授权：选孩子的账号 → 高级 → 继续 → 允许
 *   7. 看下方「执行记录」，把输出整段复制出来
 */

var API = 'https://classroom.googleapis.com/v1';
var COURSE_LIMIT = 15;
var TIME_BUDGET_MS = 4.5 * 60 * 1000;   // Apps Script 单次执行上限 6 分钟

var LOG = [];

function say(s) {
  LOG.push(s);
  console.log(s);
}

/**
 * 只调用这一个函数。
 */
function probe() {
  LOG = [];
  var t0 = Date.now();

  say('=== Google Classroom 数据可达性探针 ===');
  say('时间：' + new Date().toISOString());

  var email = '';
  try { email = Session.getActiveUser().getEmail(); } catch (e) { }
  say('账号：' + (email || '（读不到，Session.getActiveUser() 返回空）'));

  // ---- 关卡 1：列课程 ----
  say('');
  say('[1] 列课程 courses.list');
  var cr = getAll_('/courses', { studentId: 'me', courseStates: 'ACTIVE', pageSize: 50 }, 'courses');
  if (cr.error) {
    say('✗ 失败：HTTP ' + cr.error.code);
    say(JSON.stringify(cr.error.doc).slice(0, 600));
    say('');
    say(hint_(cr.error.code, JSON.stringify(cr.error.doc)));
    return finish_({ ok: false, gate: 'courses', email: email });
  }

  var courses = cr.items;
  say('✓ ' + courses.length + ' 门进行中的课程');
  courses.forEach(function (c) {
    say('   - ' + c.name + '   (id=' + c.id + ', tz=' + c.timeZone + ')');
  });

  if (!courses.length) {
    say('');
    say('⚠ 这个账号没有进行中的课程。可能是登录了错账号，或者课程都被归档了。');
    return finish_({ ok: false, gate: 'empty', email: email });
  }

  // ---- 关卡 2：每门课的作业 + 提交状态 ----
  say('');
  say('[2] 每门课的作业 + 提交状态（这是关键）');

  var totalWork = 0, totalSubs = 0, totalOpen = 0;
  var perCourse = [], scopeDenied = [], samples = [];

  for (var i = 0; i < courses.length && i < COURSE_LIMIT; i++) {
    if (Date.now() - t0 > TIME_BUDGET_MS) {
      say('! 接近 Apps Script 执行时限，提前结束');
      break;
    }
    var c = courses[i];

    var wr = getAll_('/courses/' + c.id + '/courseWork',
      { courseWorkStates: 'PUBLISHED', pageSize: 100 }, 'courseWork');
    if (wr.error) {
      say('✗ ' + c.name + '：列作业失败 HTTP ' + wr.error.code);
      say('   ' + hint_(wr.error.code, JSON.stringify(wr.error.doc)));
      perCourse.push({ course: c.name, error: wr.error.code });
      continue;
    }
    var work = wr.items;

    var sr = getAll_('/courses/' + c.id + '/courseWork/-/studentSubmissions',
      { userId: 'me', pageSize: 100 }, 'studentSubmissions');

    // 通配符 "-" 失败时，必须区分「不支持通配符」和「真的没权限」。
    // 不区分就会把可用场景误判成被学校拦了。
    if (sr.error && work.length) {
      var okPerItem = false;
      for (var k = 0; k < work.length && k < 3; k++) {
        var t = fetch_('/courses/' + c.id + '/courseWork/' + work[k].id + '/studentSubmissions',
          { userId: 'me', pageSize: 100 });
        if (t.code === 200) { okPerItem = true; break; }
      }
      if (okPerItem) {
        say('! ' + c.name + '：通配符 "-" 不可用，改为逐份取');
        sr = { items: [] };
        for (var j = 0; j < work.length; j++) {
          if (Date.now() - t0 > TIME_BUDGET_MS) break;
          var r2 = getAll_('/courses/' + c.id + '/courseWork/' + work[j].id + '/studentSubmissions',
            { userId: 'me', pageSize: 100 }, 'studentSubmissions');
          if (r2.error) { sr = { error: r2.error }; break; }
          sr.items = sr.items.concat(r2.items);
        }
      }
    }

    if (sr.error) {
      say('✗ ' + c.name + '：' + work.length + ' 份作业，但拿不到提交状态 HTTP ' + sr.error.code);
      say('   ' + hint_(sr.error.code, JSON.stringify(sr.error.doc)));
      scopeDenied.push(c.name);
      perCourse.push({ course: c.name, coursework: work.length, error: sr.error.code });
      continue;
    }

    var byWork = {};
    sr.items.forEach(function (s) { byWork[s.courseWorkId] = s; });

    var open = 0;
    work.forEach(function (w) {
      var s = byWork[w.id];
      var state = s ? s.state : null;
      if (state !== 'TURNED_IN' && state !== 'RETURNED') {
        open++;
        if (samples.length < 8) {
          samples.push({
            course: c.name,
            title: w.title,
            due: dueText_(w),
            state: state || '(无提交记录)',
            late: s ? !!s.late : null
          });
        }
      }
    });

    totalWork += work.length;
    totalSubs += sr.items.length;
    totalOpen += open;
    say('✓ ' + pad_(c.name, 24) + ' 作业 ' + work.length + '，提交 ' + sr.items.length + '，未完成 ' + open);
    perCourse.push({ course: c.name, coursework: work.length, submissions: sr.items.length, open: open });
  }

  // ---- 结论 ----
  say('');
  say('=== 结论 ===');

  if (scopeDenied.length) {
    say('⚠ 数据只拿到一半：课程和作业 OK，但「交没交」拿不到。');
    say('   被拒的课：' + scopeDenied.join(', '));
    say('   通常是 classroom.student-submissions.me.readonly 没被同意，或被域策略单独拦了。');
    say('   没有提交状态，就无法区分「已完成」和「未完成」，只能做纯 deadline 日历。');
  } else {
    say('✓ 全部拿到了。这条路通。');
    say('   课程 ' + courses.length + ' 门 / 作业 ' + totalWork + ' 份 / ' +
        '提交记录 ' + totalSubs + ' 条 / 未完成 ' + totalOpen + ' 项');
    say('');
    say('--- 未完成样例（这就是看板要显示的东西）---');
    samples.forEach(function (s) {
      say('  [' + s.course + '] ' + s.title);
      say('       截止 ' + s.due + '   ·   状态 ' + s.state + (s.late ? '   ·   已逾期' : ''));
    });
  }

  return finish_({
    ok: !scopeDenied.length,
    email: email,
    courses: courses.length,
    coursework: totalWork,
    submissions: totalSubs,
    open: totalOpen,
    perCourse: perCourse,
    samples: samples
  });
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

function fetch_(path, params) {
  var qs = Object.keys(params || {}).map(function (k) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
  }).join('&');
  var url = API + path + (qs ? '?' + qs : '');

  var res = UrlFetchApp.fetch(url, {
    method: 'get',
    headers: { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() },
    muteHttpExceptions: true
  });

  var code = res.getResponseCode();
  var text = res.getContentText();
  var doc;
  try { doc = JSON.parse(text); } catch (e) { doc = { raw: text }; }
  return { code: code, doc: doc };
}

function getAll_(path, params, key) {
  var items = [], token = null, pages = 0;
  while (true) {
    var p = {};
    for (var k in params) p[k] = params[k];
    if (token) p.pageToken = token;

    var r = fetch_(path, p);
    if (r.code !== 200) return { error: r };
    items = items.concat(r.doc[key] || []);
    token = r.doc.nextPageToken;
    pages++;
    if (!token || pages > 20) break;
  }
  return { items: items };
}

function pad_(s, n) {
  s = String(s);
  while (s.length < n) s += ' ';
  return s;
}

function pad2_(n) {
  return n < 10 ? '0' + n : String(n);
}

function dueText_(w) {
  if (!w.dueDate) return '无截止日期';
  var d = w.dueDate;
  var s = d.month + '月' + d.day + '日';
  if (w.dueTime) {
    s += ' ' + pad2_(w.dueTime.hours || 0) + ':' + pad2_(w.dueTime.minutes || 0);
  }
  return s;
}

function hint_(code, text) {
  var raw = String(text || '');
  var low = raw.toLowerCase();

  // 403 有两种完全不同的原因，必须分开，否则会把人引到错误的方向：
  //   SERVICE_DISABLED —— API 没在项目里启用（只需点一下 Enable）
  //   PERMISSION_DENIED + 域策略 —— 账号层面被禁（没法自救）
  if (raw.indexOf('SERVICE_DISABLED') >= 0 || low.indexOf('has not been used in project') >= 0) {
    var m = raw.match(/project=(\d+)/) || raw.match(/"containerInfo"\s*:\s*"(\d+)"/);
    var pid = m ? m[1] : '（见报错里的 containerInfo）';
    return '403，但原因不是权限：Classroom API 还没在脚本所属的 Cloud 项目里启用。\n' +
      '   项目号：' + pid + '\n' +
      '   修法（二选一，推荐 a）：\n' +
      '   (a) 编辑器左侧 Services → 加号 → 找到 Classroom API → 添加（会自动启用）\n' +
      '   (b) 用孩子的账号打开：\n' +
      '       https://console.developers.google.com/apis/api/classroom.googleapis.com/overview?project=' + pid + '\n' +
      '       点 Enable，等 1-2 分钟再重跑 probe';
  }

  if (code === 401) return '401：token 无效，重新运行一次并重新授权。';

  if (code === 403) {
    if (low.indexOf('insufficient') >= 0 || low.indexOf('scope') >= 0) {
      return '403 权限不足：缺 classroom.student-submissions.me.readonly。确认 appsscript.json 里的 oauthScopes 已加。';
    }
    return '403 被拒绝：账号在域层面被禁止访问 Classroom API（这类拦法自己改不了）。';
  }

  if (code === 404) return '404：Classroom API 没启用，或者 courseId 不对。';
  if (code === 429) return '429：配额超限，等一会儿再跑。';
  return code + '：' + raw.slice(0, 300);
}

function finish_(obj) {
  say('');
  say('=== JSON（方便贴给我）===');
  say(JSON.stringify(obj));
  return obj;
}


// ===========================================================================
// 以下是「Web App 桥」部分：把数据变成 macOS app 能直接拉的 JSON
// ===========================================================================

/**
 * GET 入口。部署成 Web App 后，app 就请求这个地址。
 *
 * 安全模型：URL 里必须带 ?k=<SECRET>，SECRET 存在脚本属性里。
 * 这是「同一台机器上的自家 app」这个量级够用的做法——作业标题不是机密，
 * 但也不该让拿到 URL 的人随便读。真正的边界是：URL + secret 都只存在你家。
 */
function doGet(e) {
  e = e || {};
  var params = e.parameter || {};

  var secret = PropertiesService.getScriptProperties().getProperty('SECRET');
  if (!secret) {
    return json_({ ok: false, error: 'no_secret',
                   message: '先在编辑器里运行一次 installSecret' });
  }
  if (params.k !== secret) {
    return json_({ ok: false, error: 'bad_secret' });
  }

  var cache = CacheService.getScriptCache();
  var hit = cache.get('payload');
  if (hit) return json_(hit);

  var data = collect_();
  if (data && data.ok) {
    try { cache.put('payload', JSON.stringify(data), 60); } catch (err) { }
  }
  return json_(data);
}

/**
 * 生成并记住访问密钥。运行一次，把日志里的两行记下来填进 app。
 */
function installSecret() {
  var props = PropertiesService.getScriptProperties();
  var s = props.getProperty('SECRET');
  if (!s) {
    s = (Utilities.getUuid() + Utilities.getUuid()).replace(/-/g, '');
    props.setProperty('SECRET', s);
  }
  var url = '';
  try { url = ScriptApp.getService().getUrl() || ''; } catch (e) { }

  console.log('==========================================');
  console.log('把下面两样填进 作业看板 app 的设置里：');
  console.log('');
  console.log('URL    : ' + (url || '（还没部署，先按 README 部署成 Web App，再跑一次本函数）'));
  console.log('Secret : ' + s);
  console.log('==========================================');
  return { url: url, secret: s };
}

function json_(obj) {
  var s = (typeof obj === 'string') ? obj : JSON.stringify(obj);
  return ContentService.createTextOutput(s).setMimeType(ContentService.MimeType.JSON);
}

/**
 * 真正取数据的地方。app 和 probe 共用这一份逻辑，避免两边判断不一致。
 *
 * 只返回「未完成」的条目。已完成（TURNED_IN / RETURNED）直接丢弃——
 * 过滤在服务端做，客户端就不用再懂 SUBMISSION_STATE 的语义。
 */
function collect_() {
  var t0 = Date.now();
  var email = '';
  try { email = Session.getActiveUser().getEmail(); } catch (e) { }

  var out = {
    ok: true,
    schema: 2,
    generated_at: new Date().toISOString(),
    email: email,
    counts: { courses: 0, coursework: 0, submissions: 0, open: 0, materials: 0, announcements: 0 },
    warnings: [],
    courses: [],
    topics: [],
    items: [],
    materials: [],
    announcements: []
  };

  var cr = getAll_('/courses', { studentId: 'me', courseStates: 'ACTIVE', pageSize: 50 }, 'courses');
  if (cr.error) {
    return { ok: false, error: 'courses.list', code: cr.error.code,
             hint: hint_(cr.error.code, JSON.stringify(cr.error.doc)) };
  }
  out.counts.courses = cr.items.length;

  for (var i = 0; i < cr.items.length; i++) {
    if (Date.now() - t0 > TIME_BUDGET_MS) {
      out.warnings.push({ what: 'time_budget', detail: '还有课程没取完' });
      break;
    }

    var c = cr.items[i];
    var cid = c.id;
    var cname = c.name || cid;

    // 只有老师能创建作业/资料，所以这两处的 creatorUserId 构成"老师集合"，
    // 用来判断公告是老师发的还是同学发的。反查名字需要 profile/rosters 权限，
    // 学生账号通常拿不到——但角色这个维度不需要额外权限就能推出来。
    var teacherIds = {};
    var myId = null;
    var nameCache = { enabled: true, map: {} };

    // ---- 主题（单元）名：作业和资料都靠它分组 ----
    var topicNames = {};
    var tr = getAll_('/courses/' + cid + '/topics', { pageSize: 100 }, 'topic');
    if (tr.error) {
      out.warnings.push({ course: cname, what: 'topics.list', code: tr.error.code });
    } else {
      for (var ti = 0; ti < tr.items.length; ti++) {
        var tp = tr.items[ti];
        topicNames[tp.topicId] = tp.name;
        out.topics.push({ course: cname, course_id: cid, id: tp.topicId, name: tp.name });
      }
    }

    // ---- 作业 + 提交状态 ----
    var wr = getAll_('/courses/' + cid + '/courseWork',
                     { courseWorkStates: 'PUBLISHED', pageSize: 100 }, 'courseWork');
    if (wr.error) {
      out.warnings.push({ course: cname, what: 'courseWork.list', code: wr.error.code });
    } else {
      var work = wr.items;
      var sr = getAll_('/courses/' + cid + '/courseWork/-/studentSubmissions',
                       { userId: 'me', pageSize: 100 }, 'studentSubmissions');

      // 通配符失败时区分「不支持」和「没权限」，否则会误判成被域拦
      if (sr.error && work.length) {
        var okPerItem = false;
        for (var k = 0; k < work.length && k < 3; k++) {
          var probeOne = fetch_('/courses/' + cid + '/courseWork/' + work[k].id + '/studentSubmissions',
                                { userId: 'me', pageSize: 100 });
          if (probeOne.code === 200) { okPerItem = true; break; }
        }
        if (!okPerItem) {
          return { ok: false, error: 'studentSubmissions.list', code: sr.error.code,
                   hint: hint_(sr.error.code, JSON.stringify(sr.error.doc)) };
        }
        sr = { items: [] };
        for (var j = 0; j < work.length; j++) {
          if (Date.now() - t0 > TIME_BUDGET_MS) break;
          var r2 = getAll_('/courses/' + cid + '/courseWork/' + work[j].id + '/studentSubmissions',
                           { userId: 'me', pageSize: 100 }, 'studentSubmissions');
          if (r2.error) { sr = { error: r2.error }; break; }
          sr.items = sr.items.concat(r2.items);
        }
        if (sr.error) {
          return { ok: false, error: 'studentSubmissions.list', code: sr.error.code,
                   hint: hint_(sr.error.code, JSON.stringify(sr.error.doc)) };
        }
      }

      out.counts.coursework += work.length;
      out.counts.submissions += sr.items.length;

      var byWork = {};
      sr.items.forEach(function (s) { byWork[s.courseWorkId] = s; });

      work.forEach(function (w) { if (w.creatorUserId) teacherIds[w.creatorUserId] = true; });
      if (!myId && sr.items.length) myId = sr.items[0].userId;

      var openHere = 0;
      for (var w = 0; w < work.length; w++) {
        var item = work[w];
        var sub = byWork[item.id];
        var state = sub ? sub.state : null;
        if (state === 'TURNED_IN' || state === 'RETURNED') continue;

        openHere++;
        out.items.push({
          course: cname,
          course_id: cid,
          title: item.title || '(无标题)',
          topic: topicNames[item.topicId] || '',
          due_epoch: dueEpoch_(item),
          due_label: dueLabel_(item),
          has_time: !!item.dueTime,
          state: state || '',
          late: sub ? !!sub.late : false,
          points: (typeof item.maxPoints === 'number') ? item.maxPoints : null,
          kind: (String(item.workType || '').indexOf('_QUESTION') >= 0) ? '测验' : '',
          link: item.alternateLink || ''
        });
      }
      out.counts.open += openHere;
      out.courses.push({ id: cid, name: cname, open: openHere });
    }

    // ---- 资料（Classwork → Materials）----
    var mr = getAll_('/courses/' + cid + '/courseWorkMaterials',
                     { courseWorkMaterialStates: 'PUBLISHED', pageSize: 100 }, 'courseWorkMaterial');
    if (mr.error) {
      out.warnings.push({ course: cname, what: 'courseWorkMaterials.list', code: mr.error.code });
    } else {
      for (var mi = 0; mi < mr.items.length; mi++) {
        var mat = mr.items[mi];
        if (mat.creatorUserId) teacherIds[mat.creatorUserId] = true;
        out.materials.push({
          course: cname,
          course_id: cid,
          title: mat.title || '(无标题)',
          topic: topicNames[mat.topicId] || '',
          kind: firstMaterialKind_(mat.materials),
          created_epoch: mat.creationTime ? Date.parse(mat.creationTime) : null,
          link: mat.alternateLink || ''
        });
      }
      out.counts.materials += mr.items.length;
    }

    // ---- 公告（Stream）----
    var ar = getAll_('/courses/' + cid + '/announcements',
                     { announcementStates: 'PUBLISHED', pageSize: 100 }, 'announcements');
    if (ar.error) {
      out.warnings.push({ course: cname, what: 'announcements.list', code: ar.error.code });
    } else {
      for (var ai = 0; ai < ar.items.length; ai++) {
        var ann = ar.items[ai];
        // teacher / student / me；判不出来就留空，宁可不标也不瞎标
        var author = '';
        if (ann.creatorUserId) {
          if (myId && ann.creatorUserId === myId) {
            author = 'me';
          } else if (teacherIds[ann.creatorUserId]) {
            author = 'teacher';
          } else if (Object.keys(teacherIds).length) {
            author = 'student';
          }
        }
        out.announcements.push({
          course: cname,
          course_id: cid,
          author: author,
          creator: nameFor_(ann.creatorUserId, nameCache),
          text: truncate_(ann.text, 600),
          kind: firstMaterialKind_(ann.materials),
          created_epoch: ann.creationTime ? Date.parse(ann.creationTime) : null,
          link: ann.alternateLink || ''
        });
      }
      out.counts.announcements += ar.items.length;
    }
  }

  return out;
}

/// 把 creatorUserId 换成真名。
///
/// 需要 classroom.profile.emails 权限。学校域可能拦掉这个敏感权限——所以这里
/// 是"能拿到就显示，拿不到就算了"：第一次 401/403 就把开关关掉，这一轮不再试，
/// 面板退回只显示"老师 / 同学"的角色标记，不会因为名字拿不到就整块失败。
function nameFor_(userId, cache) {
  if (!userId || !cache.enabled) return '';
  if (cache.map.hasOwnProperty(userId)) return cache.map[userId];

  var r = fetch_('/userProfiles/' + encodeURIComponent(userId), {});
  if (r.code === 200 && r.doc) {
    var full = (r.doc.name && r.doc.name.fullName) || '';
    cache.map[userId] = full;
    return full;
  }
  if (r.code === 401 || r.code === 403) cache.enabled = false;
  cache.map[userId] = '';
  return '';
}

/// 附件里第一个能识别的类型，用来给列表配个图标。
function firstMaterialKind_(materials) {
  if (!materials || !materials.length) return '';
  var m = materials[0];
  if (m.driveFile) return 'drive';
  if (m.youtubeVideo) return 'video';
  if (m.link) return 'link';
  if (m.form) return 'form';
  return '';
}

function truncate_(s, n) {
  s = String(s || '');
  return s.length > n ? s.slice(0, n) + '…' : s;
}

function dueEpoch_(w) {
  if (!w.dueDate) return null;
  var d = w.dueDate, t = w.dueTime;
  var hh = t ? (t.hours || 0) : 23;
  var mm = t ? (t.minutes || 0) : 59;
  return new Date(d.year, d.month - 1, d.day, hh, mm, 0).getTime();
}

function dueLabel_(w) {
  if (!w.dueDate) return null;
  var d = w.dueDate;
  var s = d.month + '月' + d.day + '日';
  if (w.dueTime) s += ' ' + pad2_(w.dueTime.hours || 0) + ':' + pad2_(w.dueTime.minutes || 0);
  return s;
}

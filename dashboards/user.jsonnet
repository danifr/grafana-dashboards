#!/usr/bin/env -S jsonnet -J ../vendor
local grafonnet = import 'github.com/grafana/grafonnet/gen/grafonnet-v11.1.0/main.libsonnet';
local dashboard = grafonnet.dashboard;
local ts = grafonnet.panel.timeSeries;
local prometheus = grafonnet.query.prometheus;

local common = import './common.libsonnet';

local memoryUsage =
  common.tsOptions
  + ts.new('Memory Usage')
  + ts.panelOptions.withDescription(
    |||
      Per user memory usage
    |||
  )
  + ts.standardOptions.withUnit('bytes')
  + ts.queryOptions.withTargets([
    prometheus.new(
      '$PROMETHEUS_DS',
      |||
        sum(
          container_memory_working_set_bytes{name!="", pod=~"jupyter-.*", namespace=~"$hub_name"}
            * on (namespace, pod) group_left(annotation_hub_jupyter_org_username)
            group(
                kube_pod_annotations{namespace=~"$hub_name", annotation_hub_jupyter_org_username=~"(?i).*$user_name.*", pod=~"jupyter-.*"}
            ) by (pod, namespace, annotation_hub_jupyter_org_username)
        ) by (annotation_hub_jupyter_org_username, namespace)
      |||
    )
    + prometheus.withLegendFormat('{{ annotation_hub_jupyter_org_username }} - ({{ namespace }})'),
  ]);


local cpuUsage =
  common.tsOptions
  + ts.new('CPU Usage')
  + ts.panelOptions.withDescription(
    |||
      Per user CPU usage

      The measured unit are CPU cores, and they are written out with SI prefixes, so 100m means 0.1 CPU cores.
    |||
  )
  + ts.standardOptions.withUnit('sishort')
  + ts.queryOptions.withTargets([
    prometheus.new(
      '$PROMETHEUS_DS',
      |||
        sum(
          # exclude name="" because the same container can be reported
          # with both no name and `name=k8s_...`,
          # in which case sum() by (pod) reports double the actual metric
          irate(container_cpu_usage_seconds_total{name!="", pod=~"jupyter-.*"}[5m])
          * on (namespace, pod) group_left(annotation_hub_jupyter_org_username)
          group(
              kube_pod_annotations{namespace=~"$hub_name", annotation_hub_jupyter_org_username=~"(?i).*$user_name.*"}
          ) by (pod, namespace, annotation_hub_jupyter_org_username)
        ) by (annotation_hub_jupyter_org_username, namespace)
      |||
    )
    + prometheus.withLegendFormat('{{ annotation_hub_jupyter_org_username }} - ({{ namespace }})'),
  ]);

local homedirSharedUsage =
  common.tsOptions
  + ts.new('Home Directory Usage (on shared home directories)')
  + ts.panelOptions.withDescription(
    |||
      Per user home directory size, when using a shared home directory.

      Requires https://github.com/yuvipanda/prometheus-dirsize-exporter to
      be set up.

      Similar to server pod names, user names will be *encoded* here
      using the escapism python library (https://github.com/minrk/escapism).
      You can unencode them with the following python snippet:

      from escapism import unescape
      unescape('<escaped-username>', '-')
    |||
  )
  + ts.standardOptions.withUnit('bytes')
  + ts.queryOptions.withTargets([
    prometheus.new(
      '$PROMETHEUS_DS',
      |||
        sum(

          # max is used to de-duplicate data from multiple sources
          max(
            dirsize_total_size_bytes{namespace=~"$hub_name"}
          ) by (namespace, directory)

          # make namespace/directory combinations become more namespace/directory/username combinations
          * on (namespace, directory) group_right()
          group(
            # match using username_safe (kubespawner's modern "safe" scheme)
            # duplicate jupyterhub_user_group_info's username_safe label as directory
            label_replace(
              jupyterhub_user_group_info{namespace=~"$hub_name", username_safe=~".*"},
              "directory", "$1", "username_safe", "(.+)"
            )
            or
            # match using username_escaped (kubespawner's legacy "escape" scheme)
            # duplicate jupyterhub_user_group_info's username_escaped label as directory
            label_replace(
              jupyterhub_user_group_info{namespace=~"$hub_name", username_escaped=~".*"},
              "directory", "$1", "username_escaped", "(.+)"
            )
          ) by (namespace, directory, username)

        ) by (namespace, username)
      |||
    )
    + prometheus.withLegendFormat('{{ username }} - ({{ namespace }})'),
  ]);

local memoryRequests =
  common.tsOptions
  + ts.new('Memory Requests')
  + ts.panelOptions.withDescription(
    |||
      Per-user memory requests
    |||
  )
  + ts.standardOptions.withUnit('bytes')
  + ts.queryOptions.withTargets([
    prometheus.new(
      '$PROMETHEUS_DS',
      |||
        sum(
          kube_pod_container_resource_requests{resource="memory", namespace=~"$hub_name", pod=~"jupyter-.*"}  * on (namespace, pod)
          group_left(annotation_hub_jupyter_org_username) group(
            kube_pod_annotations{namespace=~"$hub_name", annotation_hub_jupyter_org_username=~"(?i).*$user_name.*"}
            ) by (pod, namespace, annotation_hub_jupyter_org_username)
        ) by (annotation_hub_jupyter_org_username, namespace)
      |||
    )
    + prometheus.withLegendFormat('{{ annotation_hub_jupyter_org_username }} - ({{ namespace }})'),
  ]);

local cpuRequests =
  common.tsOptions
  + ts.new('CPU Requests')
  + ts.panelOptions.withDescription(
    |||
      Per user CPU requests

      The measured unit are CPU cores, and they are written out with SI prefixes, so 100m means 0.1 CPU cores.
    |||
  )
  + ts.standardOptions.withUnit('sishort')
  + ts.queryOptions.withTargets([
    prometheus.new(
      '$PROMETHEUS_DS',
      |||
        sum(
          kube_pod_container_resource_requests{resource="cpu", namespace=~"$hub_name", pod=~"jupyter-.*"} * on (namespace, pod)
          group_left(annotation_hub_jupyter_org_username) group(
            kube_pod_annotations{namespace=~"$hub_name", annotation_hub_jupyter_org_username=~"(?i).*$user_name.*"}
            ) by (pod, namespace, annotation_hub_jupyter_org_username)
        ) by (annotation_hub_jupyter_org_username, namespace)
      |||
    )
    + prometheus.withLegendFormat('{{ annotation_hub_jupyter_org_username }} - ({{ namespace }})'),
  ]);

// Session lanes for the User Sessions panel. Single source of truth for the
// query refIds, lane names, colors and order (top to bottom within a user row);
// the ECharts script below receives this list as JSON, so lanes are matched by
// refId explicitly rather than assuming refId order.
//
// `subtype` is a PromQL regex (fully anchored) on `label_obi_service_subtype`.
// Pods without that label (empty value) are treated as Notebook sessions.
local sessionLanes = [
  { refId: 'A', name: 'Notebook', color: '#3b7dd8', subtype: 'notebook|' },
  { refId: 'B', name: 'MCP', color: '#f2a63b', subtype: 'mcp' },
];

// Per-lane 0/1 "running" indicator, one series per (user, namespace) so the
// same username in two hubs stays on separate rows. The `== 1` filter means the
// series is ABSENT when the session is not running (so the ECharts script sees
// gaps, not zeros). The $user_name textbox filters the users shown, consistent
// with the other panels.
local sessionIndicator(lane) =
  |||
    max by (annotation_hub_jupyter_org_username, namespace) (
      (
        (kube_pod_status_phase{namespace=~"$hub_name", phase="Running", pod=~"jupyter-.*"} == 1)
        * on (namespace, pod) group_left()
        group(
          kube_pod_labels{namespace=~"$hub_name", label_obi_service_subtype=~"%s", pod=~"jupyter-.*"}
        ) by (namespace, pod)
      )
      * on (namespace, pod) group_left(annotation_hub_jupyter_org_username)
      group(
        kube_pod_annotations{namespace=~"$hub_name", annotation_hub_jupyter_org_username=~"(?i).*$user_name.*", pod=~"jupyter-.*"}
      ) by (namespace, pod, annotation_hub_jupyter_org_username)
    )
  ||| % lane.subtype;

// ECharts "getOption" script for the User Sessions panel. It receives one
// Prometheus time-series frame per (lane, user, namespace), turns each
// contiguous run of "running" samples into a [start, end] span, and draws
// parallel lanes per user row (Notebook above, MCP below) on a shared time
// axis. Overlap shows as both lanes present over the same interval. Dotted gray lines separate rows.
local userSessionsScript =
  'const LANES = ' + std.manifestJsonMinified([
    { refId: l.refId, name: l.name, color: l.color }
    for l in sessionLanes
  ]) + ';\n' + |||
    const series = context.panel.data.series || [];
    if (!series.length) { return { title: { text: 'no data' } }; }

    // Pin the x-axis to the DASHBOARD time range (not the data extent) so this
    // panel always spans the same time window as the resource panels, even when a
    // $user_name filter leaves only one user's sessions. Fall back to undefined
    // (ECharts auto-fit) if the time range is somehow unavailable.
    const tr = context.panel.data.timeRange;
    const xMin = (tr && tr.from) ? tr.from.valueOf() : undefined;
    const xMax = (tr && tr.to) ? tr.to.valueOf() : undefined;

    // Resolve the dashboard timezone so axis labels and tooltips match the
    // dashboard's time settings (not the browser). Grafana passes it on the data
    // request as 'browser' | 'utc' | an IANA zone (e.g. 'Europe/Madrid').
    const req = context.panel.data.request || {};
    let tz = req.timezone || 'browser';
    if (tz === 'browser' || !tz) { tz = Intl.DateTimeFormat().resolvedOptions().timeZone; }
    if (tz === 'utc') { tz = 'UTC'; }
    const DTF = new Intl.DateTimeFormat('en-GB', {
      timeZone: tz, day: 'numeric', month: 'short',
      hour: '2-digit', minute: '2-digit', hour12: false
    });
    // Return {day, mon, hh, mm} for a timestamp, in the dashboard timezone.
    const parts = (ms) => {
      const p = DTF.formatToParts(new Date(ms));
      const g = (t) => (p.find(x => x.type === t) || {}).value || '';
      return { day: g('day'), mon: g('month'), hh: g('hour'), mm: g('minute') };
    };
    // "D Mon HH:MM" in the dashboard timezone.
    const fmtTs = (ms) => { const q = parts(ms); return q.day + ' ' + q.mon + ' ' + q.hh + ':' + q.mm; };
    const fmtDur = (ms) => {
      const m = Math.round(ms / 60000);
      if (m < 60) return m + ' min';
      const h = Math.floor(m / 60);
      if (h < 24) return h + 'h ' + (m % 60) + 'm';
      return Math.floor(h / 24) + 'd ' + (h % 24) + 'h ' + (m % 60) + 'm';
    };
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

    // Query step (ms), used to decide run vs gap and to extend the last sample
    // of a run. Prefer the step the Prometheus datasource reports on the time
    // field, then the smallest sample spacing seen in any frame, then the
    // requested interval.
    function stepOf(frames) {
      let best = Infinity;
      for (const f of frames) {
        const t = f.fields.find(x => x.type === 'time');
        if (!t) continue;
        if (t.config && t.config.interval > 0) return t.config.interval;
        for (let i = 1; i < t.values.length; i++) {
          const d = t.values[i] - t.values[i - 1];
          if (d > 0 && d < best) best = d;
        }
      }
      if (best !== Infinity) return best;
      if (req.intervalMs > 0) return req.intervalMs;
      return 60000;
    }
    const step = stepOf(series);
    const gap = step * 2.5; // tolerate one missed scrape before splitting a span

    const laneByRef = {};
    LANES.forEach((l, i) => { laneByRef[l.refId] = i; });

    // One row per (user, namespace).
    const rowsByKey = {};
    const spans = [];
    for (const f of series) {
      const lane = laneByRef[f.refId];
      if (lane === undefined) continue;
      const tf = f.fields.find(x => x.type === 'time');
      const vf = f.fields.find(x => x.type === 'number');
      if (!tf || !vf) continue;
      const labels = vf.labels || {};
      const user = labels.annotation_hub_jupyter_org_username || f.name || '?';
      const ns = labels.namespace || '';
      const key = user + '\u0000' + ns;
      rowsByKey[key] = { user, ns };
      const T = tf.values, V = vf.values;
      const push = (s, e) => {
        const start = (xMin !== undefined) ? Math.max(s, xMin) : s;
        const end = (xMax !== undefined) ? Math.min(e, xMax) : e;
        if (end > start) spans.push({ key, lane, start, end });
      };
      let s = null, last = null;
      for (let i = 0; i < V.length; i++) {
        const on = V[i] != null && !Number.isNaN(V[i]) && V[i] >= 1;
        const ts = T[i];
        if (on) {
          if (s === null) { s = ts; last = ts; }
          else if (ts - last <= gap) { last = ts; }
          else { push(s, last + step); s = ts; last = ts; }
        }
      }
      if (s !== null) push(s, last + step);
    }
    if (!spans.length) { return { title: { text: 'no sessions in range' } }; }

    // Rows sorted by user then namespace; the namespace is only shown when the
    // selection spans more than one hub. The y-axis is inverted so the first
    // row is at the top.
    const rowKeys = Object.keys(rowsByKey).sort((a, b) => {
      const ra = rowsByKey[a], rb = rowsByKey[b];
      return ra.user.localeCompare(rb.user) || ra.ns.localeCompare(rb.ns);
    });
    const rowIdx = {};
    rowKeys.forEach((k, i) => { rowIdx[k] = i; });
    const multiNs = new Set(rowKeys.map(k => rowsByKey[k].ns)).size > 1;
    // Names longer than 15 characters show their first 8 and last 6 characters
    // separated by an ellipsis (e.g. "john.doe…le.com") to fit the fixed axis.
    const shorten = (u) => (u.length > 15) ? (u.slice(0, 8) + '\u2026' + u.slice(-6)) : u;
    const nsSuffix = (r) => multiNs ? ' (' + r.ns + ')' : '';
    const rowLabels = rowKeys.map(k => shorten(rowsByKey[k].user) + nsSuffix(rowsByKey[k]));
    const rowFull = rowKeys.map(k => rowsByKey[k].user + nsSuffix(rowsByKey[k]));

    // Per row and lane: total running time and number of sessions in range.
    // Spans of one series never overlap each other, so a plain sum is exact.
    const totals = {};
    for (const sp of spans) {
      const t = (totals[sp.key + '|' + sp.lane] = totals[sp.key + '|' + sp.lane] || { ms: 0, n: 0 });
      t.ms += sp.end - sp.start;
      t.n += 1;
    }

    const nLanes = LANES.length;

    function renderItem(params, api) {
      const row = api.value(0);
      const slot = api.value(3);
      const start = api.coord([api.value(1), row]);
      const end = api.coord([api.value(2), row]);
      const rowH = api.size([0, 1])[1];
      const band = rowH * 0.86;          // vertical space used by all lanes of a row
      const laneH = band / nLanes;
      const pad = laneH * 0.06;          // small gap between adjacent lanes
      const top = start[1] - band / 2 + slot * laneH + pad;
      return {
        type: 'rect',
        shape: { x: start[0], y: top, width: Math.max(end[0] - start[0], 2), height: laneH - 2 * pad },
        style: api.style()
      };
    }
    // Dotted separators between adjacent rows. Drawn by a SINGLE custom data
    // item whose renderItem returns a group of lines (one per boundary). Using a
    // single item avoids ECharts culling per-datum items whose x-value falls at
    // the axis edge (which previously made some/all separators disappear). Each
    // line spans the full plot width via params.coordSys.
    const xRef = (xMin !== undefined) ? xMin : spans[0].start;
    function renderSeparators(params, api) {
      const cs = params.coordSys;
      const children = [];
      for (let i = 1; i < rowKeys.length; i++) {
        const cCur = api.coord([xRef, i]);
        const cPrev = api.coord([xRef, i - 1]);
        const y = (cCur[1] + cPrev[1]) / 2;
        children.push({
          type: 'line',
          shape: { x1: cs.x, y1: y, x2: cs.x + cs.width, y2: y },
          style: { stroke: 'rgba(128,128,128,0.45)', lineWidth: 1, lineDash: [4, 4] }
        });
      }
      return { type: 'group', children: children };
    }
    // A single separator datum; its x is the axis midpoint so it is always within
    // range and never culled. renderSeparators draws all boundary lines from it.
    const midX = (xMin !== undefined && xMax !== undefined) ? (xMin + xMax) / 2 : spans[0].start;
    const sepData = [{ value: [0, midX, midX] }];

    const laneSeries = LANES.map((lane, li) => ({
      name: lane.name,
      type: 'custom',
      renderItem: renderItem,
      encode: { x: [1, 2], y: 0 },
      clip: true,
      z: 2,
      itemStyle: { color: lane.color },
      data: spans.filter(sp => sp.lane === li).map(sp => ({
        value: [rowIdx[sp.key], sp.start, sp.end, li, li, sp.key]
      }))
    }));

    // Restore native-like "drag to set time range". ECharts handles its own mouse
    // events, so we enable the data-zoom select cursor and, when the user drags a
    // region, push the selected [from, to] to the dashboard via locationService
    // (same effect as dragging on a built-in time series panel, including a
    // browser history entry so Back undoes the zoom). Handlers are removed first
    // so they are not stacked on each re-render.
    if (context.panel.chart) {
      setTimeout(function () {
        context.panel.chart.dispatchAction({ type: 'takeGlobalCursor', key: 'dataZoomSelect', dataZoomSelectActive: true });
      }, 300);
      context.panel.chart.off('datazoom');
      context.panel.chart.on('datazoom', function (params) {
        var b = params.batch && params.batch[0];
        var from = b && (b.startValue !== undefined ? b.startValue : b.start);
        var to = b && (b.endValue !== undefined ? b.endValue : b.end);
        if (from !== undefined && to !== undefined) {
          context.grafana.locationService.partial({ from: Math.round(from), to: Math.round(to) }, false);
        }
      });
    }

    return {
      tooltip: {
        formatter: (p) => {
          if (p.seriesName === 'sep') return '';
          const v = p.value;
          const lane = LANES[v[4]].name;
          const t = totals[v[5] + '|' + v[4]] || { ms: 0, n: 0 };
          return esc(rowFull[v[0]]) + ' · ' + esc(lane) + '<br/>' +
            fmtTs(v[1]) + ' → ' + fmtTs(v[2]) + ' (' + fmtDur(v[2] - v[1]) + ')<br/>' +
            'Total ' + esc(lane) + ' in range: ' + fmtDur(t.ms) +
            ' (' + t.n + ' session' + (t.n === 1 ? '' : 's') + ')';
        },
        textStyle: { fontSize: 12 }
      },
      // Hidden x-axis data-zoom region select (activated as the global cursor
      // above). Dragging a region fires the 'datazoom' event handled above, which
      // updates the dashboard time range. yAxisIndex 'none' keeps it x-only.
      toolbox: { show: false, feature: { dataZoom: { yAxisIndex: 'none', icon: { zoom: 'path://', back: 'path://' } } } },
      legend: { data: LANES.map(l => l.name), top: 0, left: 'center' },
      // Align the plot area with the other (timeseries) panels, which use a fixed
      // y-axis width of 140px (see axisWidth / withFixedAxisWidth below). grid.left
      // must equal that width and containLabel must be false so the plot starts at
      // a fixed offset, otherwise the x-axes of this panel and the resource panels
      // do not line up. Labels are shortened above and truncated as a fallback.
      grid: { left: 140, right: 8, top: 28, bottom: 40, containLabel: false },
      xAxis: {
        type: 'time', min: xMin, max: xMax,
        // Render tick labels in the dashboard timezone. Show the date at day
        // boundaries (00:00) and HH:MM otherwise, so the axis stays compact.
        axisLabel: {
          formatter: (val) => {
            const q = parts(val);
            return (q.hh === '00' && q.mm === '00') ? (q.day + ' ' + q.mon) : (q.hh + ':' + q.mm);
          }
        }
      },
      yAxis: {
        type: 'category', data: rowLabels, inverse: true,
        axisLabel: { width: 130, overflow: 'truncate' }
      },
      series: [
        { name: 'sep', type: 'custom', renderItem: renderSeparators, encode: { x: [1, 2], y: 0 }, data: sepData, silent: true, z: 1 }
      ].concat(laneSeries)
    };
  |||;

// User Sessions: two parallel lanes per user (Notebook / MCP) on a shared
// time axis, rendered with the Business Charts (ECharts)
// panel. This replaces the single-row state timeline so that each session type
// reads as one continuous bar and simultaneous sessions are visible as lanes
// overlapping in time (rather than being encoded as a third color).
//
// NOTE: this panel requires the `volkovlabs-echarts-panel` plugin to be
// installed in the Grafana workspace. On Amazon Managed Grafana it must be
// enabled from the plugin catalog (plugin management must be on).
local userSessions = {
  type: 'volkovlabs-echarts-panel',
  title: 'User Sessions',
  description: |||
    When each user's servers were running, over the selected time range.

    Each user has parallel lanes sharing the same time axis: `Notebook` (upper,
    blue) and `MCP` (lower, orange). Servers without a
    `label_obi_service_subtype` label count as Notebook. Each lane is a
    continuous bar for the full duration that session type was running, so a
    simultaneous Notebook + MCP session shows as both lanes overlapping in time.
    Hover a bar for its start, end and duration, plus that user's total time
    and session count for the lane in the selected range. Durations are
    accurate to the query step. A dotted line separates users; when several
    hubs are selected, the hub namespace is appended to the username.

    Based on `kube_pod_status_phase{phase="Running"}` for `jupyter-*` pods,
    joined to the hub username annotation and `label_obi_service_subtype`.
  |||,
  // Panel-level datasource uses type 'prometheus' (not the generic 'datasource'
  // placeholder) so the OBI import script
  // (infrateam-tools/eks/jupyterhub/import_grafana_dashboards.sh), which
  // rewrites every object with type=='prometheus' to the real datasource uid and
  // strips the PROMETHEUS_DS template variable, also rewrites this reference.
  // Otherwise the panel keeps a dangling '$PROMETHEUS_DS' uid and Grafana
  // reports "datasource not found". (This repo's deploy.py does no such
  // rewriting; there the '$PROMETHEUS_DS' variable resolves as usual.)
  datasource: { type: 'prometheus', uid: '$PROMETHEUS_DS' },
  targets: [
    prometheus.new('$PROMETHEUS_DS', sessionIndicator(lane))
    + prometheus.withRefId(lane.refId)
    + prometheus.withLegendFormat('{{ annotation_hub_jupyter_org_username }} - ({{ namespace }})')
    for lane in sessionLanes
  ],
  options: {
    getOption: userSessionsScript,
    renderer: 'canvas',
    themeEditor: { config: '{}', name: 'default' },
    editor: { height: 600, format: 'auto' },
  },
};

// A fixed Y-axis width applied to every panel so their plot areas start at the
// same horizontal offset and the time (x) axes line up across panels. The
// "User Sessions" panel has a text (username) y-axis while the resource panels
// have numeric axes of a different width, so without this they do not align.
// The ECharts panel ignores fieldConfig; its offset is set via grid.left in
// userSessionsScript, which must match axisWidth.
local axisWidth = 140;
local withFixedAxisWidth(panel) =
  if panel.type == 'volkovlabs-echarts-panel' then panel
  else panel {
    fieldConfig+: { defaults+: { custom+: { axisWidth: axisWidth } } },
  };

dashboard.new('User Diagnostics Dashboard')
+ dashboard.withTags(['jupyterhub'])
+ dashboard.withUid('user-diagnostics-dashboard')
+ dashboard.withEditable(true)
+ dashboard.withVariables([
  common.variables.prometheus,
  common.variables.hub_name,
  common.variables.user_name,
])
+ dashboard.withPanels(
  grafonnet.util.grid.makeGrid(
    std.map(withFixedAxisWidth, [
      userSessions,
      memoryUsage,
      cpuUsage,
      homedirSharedUsage,
      memoryRequests,
      cpuRequests,
    ]),
    panelWidth=24,
    panelHeight=12,
  )
)

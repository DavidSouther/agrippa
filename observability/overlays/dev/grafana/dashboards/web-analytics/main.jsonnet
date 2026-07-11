local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

local mimir = 'PAE45454D0EDB9216';

local prometheus = g.query.prometheus;
local target(refId, expr) = prometheus.new(mimir, expr) + prometheus.withRefId(refId);

local stat = g.panel.stat;
local ts = g.panel.timeSeries;
local barGauge = g.panel.barGauge;
local table = g.panel.table;

local statPanel(title, unit, decimals, gridPos, expr) =
  stat.new(title)
  + stat.panelOptions.withGridPos(gridPos.h, gridPos.w, gridPos.x, gridPos.y)
  + stat.queryOptions.withDatasource('prometheus', mimir)
  + stat.queryOptions.withTargets([target('A', expr)])
  + stat.standardOptions.withUnit(unit)
  + stat.standardOptions.withDecimals(decimals)
  + stat.options.reduceOptions.withCalcs(['lastNotNull'])
  + stat.options.withColorMode('value')
  + stat.options.withGraphMode('area');

g.dashboard.new('Web Analytics (Istio Gateway)')
+ g.dashboard.withUid('web-analytics')
+ g.dashboard.withDescription(
  "Traffic through the shared agrippa-gateway: request volume, status codes, latency, and top destinations, sourced from Istio's istio_requests_total/istio_request_duration_milliseconds telemetry."
)
+ g.dashboard.withTags(['web', 'istio', 'gateway'])
+ g.dashboard.withTimezone('browser')
+ g.dashboard.withSchemaVersion(39)
+ g.dashboard.withRefresh('30s')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.time.withTo('now')
+ g.dashboard.withPanels([
  statPanel(
    'Total Requests',
    'short',
    0,
    { h: 4, w: 6, x: 0, y: 0 },
    'sum(increase(istio_requests_total{reporter="source"}[$__range]))'
  ),

  statPanel(
    'Requests / sec (current)',
    'reqps',
    2,
    { h: 4, w: 6, x: 6, y: 0 },
    'sum(rate(istio_requests_total{reporter="source"}[5m]))'
  ),

  statPanel(
    'Error Rate (5xx)',
    'percent',
    2,
    { h: 4, w: 6, x: 12, y: 0 },
    '100 * sum(rate(istio_requests_total{reporter="source",response_code=~"5.."}[5m])) / sum(rate(istio_requests_total{reporter="source"}[5m]))'
  )
  + stat.standardOptions.thresholds.withMode('absolute')
  + stat.standardOptions.thresholds.withSteps([
    { color: 'green', value: null },
    { color: 'orange', value: 1 },
    { color: 'red', value: 5 },
  ]),

  statPanel(
    'p95 Latency',
    'ms',
    1,
    { h: 4, w: 6, x: 18, y: 0 },
    'histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{reporter="source"}[5m])) by (le))'
  ),

  ts.new('Request Rate by Destination')
  + ts.panelOptions.withGridPos(8, 12, 0, 4)
  + ts.queryOptions.withDatasource('prometheus', mimir)
  + ts.queryOptions.withTargets([
    target('A', 'sum(rate(istio_requests_total{reporter="source"}[5m])) by (destination_service_name)')
    + prometheus.withLegendFormat('{{destination_service_name}}'),
  ])
  + ts.standardOptions.withUnit('reqps')
  + ts.fieldConfig.defaults.custom.withFillOpacity(20)
  + ts.fieldConfig.defaults.custom.stacking.withMode('normal')
  + ts.options.legend.withDisplayMode('table')
  + ts.options.legend.withPlacement('bottom')
  + ts.options.legend.withCalcs(['mean', 'max'])
  + ts.options.tooltip.withMode('multi'),

  ts.new('Requests by Status Code')
  + ts.panelOptions.withGridPos(8, 12, 12, 4)
  + ts.queryOptions.withDatasource('prometheus', mimir)
  + ts.queryOptions.withTargets([
    target('A', 'sum(rate(istio_requests_total{reporter="source"}[5m])) by (response_code)')
    + prometheus.withLegendFormat('{{response_code}}'),
  ])
  + ts.standardOptions.withUnit('reqps')
  + ts.fieldConfig.defaults.custom.withFillOpacity(20)
  + ts.fieldConfig.defaults.custom.stacking.withMode('normal')
  + ts.options.legend.withDisplayMode('table')
  + ts.options.legend.withPlacement('bottom')
  + ts.options.legend.withCalcs(['mean', 'max'])
  + ts.options.tooltip.withMode('multi'),

  barGauge.new('Top Destinations (by request count)')
  + barGauge.panelOptions.withGridPos(8, 12, 0, 12)
  + barGauge.queryOptions.withDatasource('prometheus', mimir)
  + barGauge.queryOptions.withTargets([
    target('A', 'topk(10, sum(increase(istio_requests_total{reporter="source"}[$__range])) by (destination_service_name))')
    + prometheus.withLegendFormat('{{destination_service_name}}')
    + prometheus.withInstant(true),
  ])
  + barGauge.standardOptions.withUnit('short')
  + barGauge.standardOptions.withDecimals(0)
  + barGauge.options.withDisplayMode('gradient')
  + barGauge.options.withOrientation('horizontal')
  + barGauge.options.reduceOptions.withCalcs(['lastNotNull']),

  ts.new('Latency Percentiles (all destinations)')
  + ts.panelOptions.withGridPos(8, 12, 12, 12)
  + ts.queryOptions.withDatasource('prometheus', mimir)
  + ts.queryOptions.withTargets([
    target('A', 'histogram_quantile(0.50, sum(rate(istio_request_duration_milliseconds_bucket{reporter="source"}[5m])) by (le))')
    + prometheus.withLegendFormat('p50'),
    target('B', 'histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{reporter="source"}[5m])) by (le))')
    + prometheus.withLegendFormat('p95'),
    target('C', 'histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter="source"}[5m])) by (le))')
    + prometheus.withLegendFormat('p99'),
  ])
  + ts.standardOptions.withUnit('ms')
  + ts.options.legend.withDisplayMode('list')
  + ts.options.legend.withPlacement('bottom')
  + ts.options.tooltip.withMode('multi'),

  ts.new('Error Rate by Destination (5xx)')
  + ts.panelOptions.withGridPos(8, 12, 0, 20)
  + ts.queryOptions.withDatasource('prometheus', mimir)
  + ts.queryOptions.withTargets([
    target('A', 'sum(rate(istio_requests_total{reporter="source",response_code=~"5.."}[5m])) by (destination_service_name)')
    + prometheus.withLegendFormat('{{destination_service_name}}'),
  ])
  + ts.standardOptions.withUnit('reqps')
  + ts.options.legend.withDisplayMode('table')
  + ts.options.legend.withPlacement('bottom')
  + ts.options.legend.withCalcs(['max'])
  + ts.options.tooltip.withMode('multi'),

  ts.new('Bytes Transferred')
  + ts.panelOptions.withGridPos(8, 12, 12, 20)
  + ts.queryOptions.withDatasource('prometheus', mimir)
  + ts.queryOptions.withTargets([
    target('A', 'sum(rate(istio_request_bytes_sum{reporter="source"}[5m]))')
    + prometheus.withLegendFormat('request bytes/s'),
    target('B', 'sum(rate(istio_response_bytes_sum{reporter="source"}[5m]))')
    + prometheus.withLegendFormat('response bytes/s'),
  ])
  + ts.standardOptions.withUnit('Bps')
  + ts.options.legend.withDisplayMode('list')
  + ts.options.legend.withPlacement('bottom')
  + ts.options.tooltip.withMode('multi'),

  table.new('Traffic Detail (source -> destination -> status)')
  + table.panelOptions.withGridPos(8, 24, 0, 28)
  + table.queryOptions.withDatasource('prometheus', mimir)
  + table.queryOptions.withTargets([
    target('A', 'sum by (source_workload, destination_service_name, response_code) (increase(istio_requests_total{reporter="source"}[$__range]))')
    + prometheus.withInstant(true)
    + prometheus.withFormat('table'),
  ])
  + table.standardOptions.withUnit('short')
  + table.standardOptions.withDecimals(0)
  + table.options.withShowHeader(true)
  + table.options.withSortBy([
    table.options.sortBy.withDisplayName('Value')
    + table.options.sortBy.withDesc(true),
  ])
  + table.queryOptions.withTransformations([
    table.queryOptions.transformation.withId('organize')
    + table.queryOptions.transformation.withOptions({
      excludeByName: { Time: true },
      renameByName: {
        Value: 'Requests',
        source_workload: 'Source',
        destination_service_name: 'Destination',
        response_code: 'Status',
      },
    }),
  ]),
])
+ { version: 1 }

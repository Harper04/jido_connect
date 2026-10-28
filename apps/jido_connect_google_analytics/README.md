# Jido Connect Google Analytics

Google Analytics provider package for Jido Connect.

This package depends on `jido_connect_google` for shared Google OAuth,
transport, scope, and account behavior. It keeps Analytics-specific DSL,
handlers, schemas, normalized structs, and tests package-local as those
surfaces are added.

## Status

This scaffold declares the provider package, user OAuth profile, Analytics
scope resolver, generated Jido plugin shell, shared Google transport boundary,
normalized Zoi-backed structs, metadata lookup, core report actions, and
realtime report actions, property discovery, and curated catalog packs. Trigger
work is intentionally split into later roadmap tasks.

## Normalized Structs

- `Jido.Connect.Google.Analytics.Report`
- `Jido.Connect.Google.Analytics.Row`
- `Jido.Connect.Google.Analytics.Dimension`
- `Jido.Connect.Google.Analytics.Metric`
- `Jido.Connect.Google.Analytics.PropertySummary`

## OAuth Scopes

The provider declares the shared Google identity scopes plus Analytics product
scopes:

- `openid`
- `email`
- `profile`
- `https://www.googleapis.com/auth/analytics.readonly`

## API Boundaries

- Analytics Data API traffic should use
  `Jido.Connect.Google.Analytics.Client.Transport.data_request/1`.
- Analytics Admin API traffic should use
  `Jido.Connect.Google.Analytics.Client.Transport.admin_request/1`.

Both request builders delegate to `Jido.Connect.Google.Transport` and are
configurable through application environment for tests.

## Tool Surface

- `google.analytics.metadata.get`
- `google.analytics.report.run`
- `google.analytics.report.batch_run`
- `google.analytics.report.realtime.run`
- `google.analytics.property_summaries.list`

No Analytics triggers are exposed yet. The generated plugin and provider
metadata are present so later tasks can add triggers without changing package
wiring.

## Catalog Packs

`Jido.Connect.Google.Analytics.catalog_packs/0` returns storage-free catalog
packs that hosts can pass to the catalog boundary:

- `Jido.Connect.Google.Analytics.reader_pack/0` exposes discovery-only tools:
  metadata lookup and accessible property summaries.
- `Jido.Connect.Google.Analytics.reporter_pack/0` includes the reader tools plus
  standard, batch, and realtime report execution.

Use packs with catalog search, description, and invocation:

```elixir
Jido.Connect.Catalog.search_tools("analytics",
  modules: [Jido.Connect.Google.Analytics],
  packs: Jido.Connect.Google.Analytics.catalog_packs(),
  pack: :google_analytics_reporter
)
```

## Query Shape

Analytics report dimensions, metrics, filters, orderings, and limits are
provider-specific GA4 contracts. Keep those mappings in this package rather
than adding a generic query DSL to `jido_connect` core.

Report actions accept provider-native GA4 request concepts:

- `date_ranges`: non-empty list of maps with `start_date`/`end_date` or
  `startDate`/`endDate`.
- `metrics`: non-empty list of metric names or provider metric maps, up to
  Google Analytics' 10 metric limit.
- `dimensions`: optional list of dimension names or provider dimension maps,
  up to Google Analytics' 9 dimension limit.
- `dimension_filter`, `metric_filter`, `order_bys`, `comparisons`, and
  `cohort_spec`: GA4-shaped maps/lists. Snake-case keys are converted to
  Google lower camelCase keys at the connector boundary.
- `limit`: positive integer up to 250,000 rows. `offset`: non-negative integer.

Realtime reports use a separate input shape:

- `metrics`: non-empty list of realtime metric names or provider metric maps.
- `dimensions`: optional list of realtime dimension names or provider maps.
- `minute_ranges`: optional list of up to two minute range maps with
  `start_minutes_ago`/`end_minutes_ago` or Google's lower camelCase keys.
- `dimension_filter`, `metric_filter`, `order_bys`, `metric_aggregations`, and
  `return_property_quota`: GA4 realtime request fields, mapped provider-locally.

Property discovery uses the Analytics Admin API `accountSummaries.list`
endpoint and returns flattened `Jido.Connect.Google.Analytics.PropertySummary`
values with account context in `metadata`.

## Tool Availability

Generated plugin availability is available from the scaffold and will report
one entry per generated action or trigger as those tools are added:

```elixir
Jido.Connect.Google.Analytics.Plugin.tool_availability(%{connection: connection})
```

//! Distributed tracing and error-tracking setup.
//!
//! Wires `tracing` spans into an OpenTelemetry OTLP pipeline so requests can
//! be followed end-to-end across services in Jaeger or Datadog (both accept
//! OTLP/gRPC), and installs the W3C `traceparent`/`tracestate` propagator so
//! trace context survives calls to and from other services.
//!
//! Also wires `tracing` into Sentry (see [`init_sentry`]) so panics and
//! `tracing::error!` calls are centralized instead of only living in local
//! logs.
//!
//! ## Sampling & cardinality
//!
//! - Sampling is controlled by the standard `OTEL_TRACES_SAMPLER` /
//!   `OTEL_TRACES_SAMPLER_ARG` env vars (default: `parentbased_always_on`).
//!   Set `OTEL_TRACES_SAMPLER=parentbased_traceidratio` with
//!   `OTEL_TRACES_SAMPLER_ARG=0.1` to sample 10% of root traces in prod while
//!   still honoring upstream sampling decisions propagated via `traceparent`.
//! - Cardinality: resource attributes are limited to the low-cardinality set
//!   below (`service.name`, `service.version`, `deployment.environment`,
//!   `service.instance.id`). Never attach user IDs, request IDs, evidence
//!   hashes, or other unbounded values as span/resource attributes — put them
//!   on span *events* or logs instead so they don't explode the metric index.
use std::env;
use std::time::Duration;

use opentelemetry::trace::TracerProvider as _;
use opentelemetry::{global, KeyValue};
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::trace::{Sampler, SdkTracerProvider};
use opentelemetry_sdk::Resource;
use sentry::ClientInitGuard;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

/// Handle kept alive for the lifetime of the process so spans can be flushed
/// and exported on shutdown, and so the Sentry client stays connected (and
/// flushes on drop) for the process lifetime.
pub struct TelemetryGuard {
    provider: Option<SdkTracerProvider>,
    _sentry: Option<ClientInitGuard>,
}

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        if let Some(provider) = self.provider.take() {
            if let Err(e) = provider.shutdown() {
                eprintln!("Failed to shut down tracer provider: {e}");
            }
        }
    }
}

/// Initialize the Sentry client for centralized panic/error tracking.
///
/// Set `SENTRY_DSN` to the project's DSN to enable it. When unset, this is a
/// no-op — consistent with the OTLP behavior in [`init_telemetry`], so local
/// dev without a Sentry project keeps working.
///
/// What this wires up, mapped to the issue's acceptance criteria:
/// - **Panics and errors captured**: the `panic` integration (enabled by
///   default when `sentry::init` runs) installs a panic hook that reports
///   panics to Sentry; `tracing::error!` calls are turned into Sentry events
///   by the `sentry_tracing` layer registered in [`init_telemetry`] (its
///   default event filter maps `ERROR` to an event), which is what
///   centralizes error logging instead of it only living in local/OTLP logs.
/// - **Breadcrumb trail of the last 10 requests**: `RequestTracing`
///   (`middleware/tracing_middleware.rs`) logs one `tracing::info!("request
///   completed", ...)` per finished request; the same `sentry_tracing` layer
///   turns `INFO` logs into breadcrumbs. Capping `max_breadcrumbs` at 10
///   keeps exactly the last 10 requests attached to whatever error fires
///   next, with no separate request-history buffer to maintain.
/// - **Release tracking**: `release` is set from the crate version via
///   `sentry::release_name!()` (falls back to `CARGO_PKG_NAME@CARGO_PKG_VERSION`),
///   so every event is tagged with the build that produced it.
/// - **Slack alerts on critical errors**: `before_send` posts a summary to
///   `SLACK_WEBHOOK_URL` (if set) for every event at `Error` level or above,
///   independent of Sentry's own (paid-tier) alert rules.
/// - **Error rate dashboard**: provided by Sentry's Issues/Discover views
///   automatically once events are flowing in — there is no additional
///   backend code for this piece beyond enabling the SDK above.
fn init_sentry() -> Option<ClientInitGuard> {
    let dsn = env::var("SENTRY_DSN").ok().filter(|d| !d.is_empty())?;
    let environment = env::var("APP_ENV").unwrap_or_else(|_| "development".to_string());
    let slack_webhook_url = env::var("SLACK_WEBHOOK_URL").ok().filter(|u| !u.is_empty());

    let guard = sentry::init((
        dsn,
        sentry::ClientOptions::default()
            .release(sentry::release_name!())
            .environment(environment)
            .max_breadcrumbs(10)
            .attach_stacktrace(true)
            .before_send(move |event| {
                if event.level >= sentry::Level::Error {
                    if let Some(webhook_url) = slack_webhook_url.clone() {
                        notify_slack_on_critical_error(webhook_url, summarize_event(&event));
                    }
                }
                Some(event)
            }),
    ));

    Some(guard)
}

/// One-line summary of a Sentry event for the Slack alert: the exception
/// type/value when present (panics and most `tracing::error!` calls that
/// attach an error), otherwise the event's log message.
fn summarize_event(event: &sentry::protocol::Event<'static>) -> String {
    if let Some(exception) = event.exception.values.first() {
        match &exception.value {
            Some(value) => format!("{}: {value}", exception.ty),
            None => exception.ty.clone(),
        }
    } else if let Some(message) = &event.message {
        message.clone()
    } else {
        "(no message)".to_string()
    }
}

/// Fire-and-forget a Slack alert for a critical (Error/Fatal) Sentry event.
///
/// Runs on its own thread with a short timeout so a slow or unreachable
/// Slack webhook never blocks the request/panic path that triggered it.
fn notify_slack_on_critical_error(webhook_url: String, summary: String) {
    std::thread::spawn(move || {
        let client = match reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
        {
            Ok(client) => client,
            Err(e) => {
                eprintln!("Failed to build Slack webhook client: {e}");
                return;
            }
        };

        let payload = serde_json::json!({ "text": format!(":rotating_light: *ArenaX backend error*\n{summary}") });
        if let Err(e) = client.post(&webhook_url).json(&payload).send() {
            eprintln!("Failed to send Slack alert for critical error: {e}");
        }
    });
}

/// Build the low-cardinality resource describing this service instance.
///
/// Only bounded attributes are attached here (see the module docs on
/// cardinality). `service.instance.id` defaults to the hostname so multiple
/// replicas are distinguishable without leaking anything sensitive.
fn build_resource(service_name: String) -> Resource {
    let service_version = env::var("OTEL_SERVICE_VERSION")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string());
    let environment = env::var("APP_ENV").unwrap_or_else(|_| "development".to_string());
    let instance_id = env::var("HOSTNAME")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "unknown".to_string());

    Resource::builder()
        .with_attribute(KeyValue::new("service.name", service_name))
        .with_attribute(KeyValue::new("service.version", service_version))
        .with_attribute(KeyValue::new("deployment.environment", environment))
        .with_attribute(KeyValue::new("service.instance.id", instance_id))
        .build()
}

/// Resolve the sampler from the standard `OTEL_TRACES_SAMPLER` /
/// `OTEL_TRACES_SAMPLER_ARG` env vars, defaulting to parent-based always-on
/// so upstream sampling decisions propagated via `traceparent` are honored.
fn build_sampler() -> Sampler {
    let sampler = env::var("OTEL_TRACES_SAMPLER")
        .unwrap_or_else(|_| "parentbased_always_on".to_string())
        .to_ascii_lowercase();
    let arg = env::var("OTEL_TRACES_SAMPLER_ARG")
        .ok()
        .and_then(|v| v.parse::<f64>().ok());

    match sampler.as_str() {
        "always_on" => Sampler::AlwaysOn,
        "always_off" => Sampler::AlwaysOff,
        "traceidratio" => Sampler::TraceIdRatioBased(arg.unwrap_or(1.0)),
        "parentbased_always_off" => Sampler::ParentBased(Box::new(Sampler::AlwaysOff)),
        "parentbased_traceidratio" => {
            Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(arg.unwrap_or(1.0))))
        }
        _ => Sampler::ParentBased(Box::new(Sampler::AlwaysOn)),
    }
}

/// Initialize structured logging plus (optionally) OpenTelemetry trace export.
///
/// Set `OTEL_EXPORTER_OTLP_ENDPOINT` to point at a Jaeger or Datadog Agent
/// OTLP/gRPC receiver (e.g. `http://localhost:4317`). When unset, tracing
/// still runs with the fmt layer only — no export, no panic — so local dev
/// without a collector keeps working.
pub fn init_telemetry() -> TelemetryGuard {
    let env_filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| "backend=info,actix_web=info".into());

    // Initialize Sentry before the tracing subscriber so the `sentry_tracing`
    // layer below has a live client to forward events/breadcrumbs to.
    let sentry_guard = init_sentry();
    let sentry_layer = sentry_guard.as_ref().map(|_| sentry_tracing::layer());

    global::set_text_map_propagator(TraceContextPropagator::new());

    let otlp_endpoint = env::var("OTEL_EXPORTER_OTLP_ENDPOINT").ok();

    let provider = otlp_endpoint.as_ref().and_then(|endpoint| {
        let service_name =
            env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| "arenax-backend".to_string());

        let exporter = opentelemetry_otlp::SpanExporter::builder()
            .with_tonic()
            .with_endpoint(endpoint.clone())
            .with_timeout(Duration::from_secs(3))
            .build();

        match exporter {
            Ok(exporter) => {
                let resource = build_resource(service_name);

                let provider = SdkTracerProvider::builder()
                    .with_batch_exporter(exporter)
                    .with_sampler(build_sampler())
                    .with_resource(resource)
                    .build();

                global::set_tracer_provider(provider.clone());
                Some(provider)
            }
            Err(e) => {
                eprintln!("Failed to build OTLP span exporter: {e}");
                None
            }
        }
    });

    let otel_layer = provider.as_ref().map(|p| {
        use opentelemetry::trace::TracerProvider as _;
        let tracer = p.tracer("backend");
        tracing_opentelemetry::layer().with_tracer(tracer)
    });

    tracing_subscriber::registry()
        .with(env_filter)
        .with(tracing_subscriber::fmt::layer())
        .with(otel_layer)
        .with(sentry_layer)
        .init();

    TelemetryGuard {
        provider,
        _sentry: sentry_guard,
    }
}

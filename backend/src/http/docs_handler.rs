//! OpenAPI 3.0 documentation handler — Issue #901 / #4
//!
//! Serves the versioned OpenAPI 3.0 JSON spec at `GET /api/docs/openapi.json`
//! and a lightweight Swagger UI redirect page at `GET /api/docs/`.
//!
//! The spec itself is built in [`crate::http::openapi_spec`] so that it can be
//! shared between this handler and the contract tests in
//! `backend/tests/api_contract.rs`.
//!
//! # Acceptance criteria
//!
//! ✅ Auto-generate OpenAPI 3.0 spec from code (built from `serde_json::json!`)
//! ✅ Request/response examples included per operation
//! ✅ Authentication schemes documented (Bearer JWT)
//! ✅ Rate-limit info documented per endpoint
//! ✅ Deploy endpoint ready for docs.api.arenax.com
//! ✅ Versioned contract shared with contract tests (#4)
//! ✅ Deprecation policy documented (#4)

use actix_web::{web, HttpResponse};

use crate::http::openapi_spec::build_openapi_spec;

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/docs/openapi.json
///
/// Serves the versioned OpenAPI 3.0 spec as JSON. Suitable for deploying to
/// docs.api.arenax.com and for CI diffing to catch breaking changes.
pub async fn get_openapi_spec() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/json")
        .insert_header(("Access-Control-Allow-Origin", "*"))
        .json(build_openapi_spec())
}

/// GET /api/docs/
///
/// Lightweight HTML page that loads Swagger UI from CDN and points it at
/// /api/docs/openapi.json.
pub async fn get_swagger_ui() -> HttpResponse {
    let html = r#"<!DOCTYPE html>
<html>
<head>
  <title>ArenaX API Docs</title>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" type="text/css" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>
  SwaggerUIBundle({
    url: "/api/docs/openapi.json",
    dom_id: '#swagger-ui',
    presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
    layout: "StandaloneLayout",
    deepLinking: true,
    displayRequestDuration: true,
    tryItOutEnabled: true
  });
</script>
</body>
</html>"#;

    HttpResponse::Ok()
        .content_type("text/html; charset=utf-8")
        .body(html)
}

/// Configure docs routes.
pub fn configure_routes(cfg: &mut web::ServiceConfig) {
    cfg.service(
        web::scope("/docs")
            .route("/openapi.json", web::get().to(get_openapi_spec))
            .route("",             web::get().to(get_swagger_ui))
            .route("/",            web::get().to(get_swagger_ui)),
    );
}
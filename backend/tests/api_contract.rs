//! API contract tests.
//!
//! This integration test is the CI entry point for the published backend API
//! contract. It:
//!
//! 1. Loads the OpenAPI document produced by the `openapi_spec` module.
//! 2. Validates the document (schema linting: required fields, unique
//!    operation ids, resolvable `$ref`s, documented error responses, etc.).
//! 3. Exercises every documented request/response example against the
//!    corresponding handler for the auth, tournament, match, wallet, dispute
//!    and notification endpoints.
//! 4. Guards against undetected breaking changes by comparing the current
//!    contract against the checked-in baseline (`tests/fixtures/api_contract_baseline.json`).
//!
//! Run with:
//!
//! ```text
//! cargo test --test api_contract
//! ```
//!
//! When a breaking change is intentional, bump the API version and regenerate
//! the baseline (`UPDATE_API_CONTRACT_BASELINE=1 cargo test --test api_contract`).

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use backend::openapi_spec;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Environment variable that, when set, rewrites the baseline fixture with the
/// current contract. Only use this together with an explicit version bump.
const UPDATE_BASELINE_ENV: &str = "UPDATE_API_CONTRACT_BASELINE";

/// Endpoint groups that must be covered by the contract.
const REQUIRED_TAGS: &[&str] = &[
    "auth",
    "tournament",
    "match",
    "wallet",
    "dispute",
    "notification",
];

/// HTTP methods we understand when walking the paths object.
const HTTP_METHODS: &[&str] = &[
    "get", "put", "post", "delete", "options", "head", "patch", "trace",
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn baseline_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("api_contract_baseline.json")
}

fn load_spec() -> Value {
    let spec = openapi_spec::build_spec();
    serde_json::to_value(&spec).expect("openapi spec must serialize to JSON")
}

/// Resolve a local `$ref` (e.g. `#/components/schemas/Foo`) against the spec.
fn resolve_ref<'a>(spec: &'a Value, reference: &str) -> &'a Value {
    let pointer = reference
        .strip_prefix('#')
        .unwrap_or_else(|| panic!("only local $refs are supported, got `{reference}`"));
    spec.pointer(pointer)
        .unwrap_or_else(|| panic!("unresolvable $ref `{reference}`"))
}

/// Recursively collect every `$ref` string found in a JSON value.
fn collect_refs(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if key == "$ref" {
                    if let Some(reference) = child.as_str() {
                        out.push(reference.to_string());
                    }
                } else {
                    collect_refs(child, out);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_refs(item, out);
            }
        }
        _ => {}
    }
}

/// Iterate over `(path, method, operation)` triples in the spec.
fn operations(spec: &Value) -> Vec<(String, String, Value)> {
    let mut result = Vec::new();
    let paths = spec
        .get("paths")
        .and_then(Value::as_object)
        .expect("spec must contain a `paths` object");

    for (path, item) in paths {
        let item = item
            .as_object()
            .unwrap_or_else(|| panic!("path item `{path}` must be an object"));
        for (method, operation) in item {
            if HTTP_METHODS.contains(&method.as_str()) {
                result.push((path.clone(), method.clone(), operation.clone()));
            }
        }
    }
    result
}

/// Extract the first documented example for a request body or response.
fn first_example(container: &Value) -> Option<Value> {
    // `example` directly on the media type object.
    if let Some(example) = container.get("example") {
        return Some(example.clone());
    }
    // `examples` map: take the first entry's `value`.
    if let Some(examples) = container.get("examples").and_then(Value::as_object) {
        for example in examples.values() {
            if let Some(value) = example.get("value") {
                return Some(value.clone());
            }
        }
    }
    None
}

/// Collect the documented request example for an operation, if any.
fn request_example(operation: &Value) -> Option<Value> {
    let content = operation.get("requestBody")?.get("content")?.as_object()?;
    for media in content.values() {
        if let Some(example) = first_example(media) {
            return Some(example);
        }
    }
    None
}

/// Collect the documented success (2xx) response example for an operation.
fn response_example(operation: &Value) -> Option<Value> {
    let responses = operation.get("responses")?.as_object()?;
    for (status, response) in responses {
        if !status.starts_with('2') {
            continue;
        }
        let content = match response.get("content").and_then(Value::as_object) {
            Some(content) => content,
            None => continue,
        };
        for media in content.values() {
            if let Some(example) = first_example(media) {
                return Some(example);
            }
        }
    }
    None
}

/// A minimal structural check that an example matches the shape of its schema.
///
/// This is intentionally lightweight (no external JSON-schema crate) but
/// catches the most common contract drift: missing required fields and
/// mismatched primitive types.
fn assert_example_matches_schema(spec: &Value, schema: &Value, example: &Value, context: &str) {
    let schema = if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        resolve_ref(spec, reference)
    } else {
        schema
    };

    if let Some(expected_type) = schema.get("type").and_then(Value::as_str) {
        let actual_ok = match expected_type {
            "object" => example.is_object(),
            "array" => example.is_array(),
            "string" => example.is_string(),
            "integer" => example.is_i64() || example.is_u64(),
            "number" => example.is_number(),
            "boolean" => example.is_boolean(),
            "null" => example.is_null(),
            other => panic!("{context}: unsupported schema type `{other}`"),
        };
        assert!(
            actual_ok,
            "{context}: example does not match schema type `{expected_type}`: {example}"
        );
    }

    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        let object = example
            .as_object()
            .unwrap_or_else(|| panic!("{context}: required fields but example is not an object"));
        for field in required {
            let field = field
                .as_str()
                .unwrap_or_else(|| panic!("{context}: required entries must be strings"));
            assert!(
                object.contains_key(field),
                "{context}: example is missing required field `{field}`"
            );
        }
    }

    if let (Some(properties), Some(object)) = (
        schema.get("properties").and_then(Value::as_object),
        example.as_object(),
    ) {
        for (name, property_schema) in properties {
            if let Some(value) = object.get(name) {
                assert_example_matches_schema(
                    spec,
                    property_schema,
                    value,
                    &format!("{context}.{name}"),
                );
            }
        }
    }

    if let (Some(items), Some(array)) = (
        schema.get("items"),
        example.as_array(),
    ) {
        for (index, item) in array.iter().enumerate() {
            assert_example_matches_schema(spec, items, item, &format!("{context}[{index}]"));
        }
    }
}

/// The schema associated with a request body or response media type.
fn media_schema(container: &Value) -> Option<&Value> {
    let content = container.get("content")?.as_object()?;
    for media in content.values() {
        if let Some(schema) = media.get("schema") {
            return Some(schema);
        }
    }
    None
}

/// The schema associated with the request body of an operation.
fn request_schema(operation: &Value) -> Option<&Value> {
    media_schema(operation.get("requestBody")?)
}

/// The schema associated with the first 2xx response of an operation.
fn response_schema(operation: &Value) -> Option<&Value> {
    let responses = operation.get("responses")?.as_object()?;
    for (status, response) in responses {
        if status.starts_with('2') {
            if let Some(schema) = media_schema(response) {
                return Some(schema);
            }
        }
    }
    None
}

/// A stable, order-independent fingerprint of the contract surface used to
/// detect breaking changes between builds.
fn contract_fingerprint(spec: &Value) -> Value {
    let mut paths: BTreeMap<String, BTreeMap<String, Value>> = BTreeMap::new();

    for (path, method, operation) in operations(spec) {
        let mut entry = Map::new();

        if let Some(operation_id) = operation.get("operationId") {
            entry.insert("operationId".to_string(), operation_id.clone());
        }

        let mut parameters: BTreeSet<String> = BTreeSet::new();
        if let Some(params) = operation.get("parameters").and_then(Value::as_array) {
            for param in params {
                if let Some(name) = param.get("name").and_then(Value::as_str) {
                    let location = param
                        .get("in")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let required = param
                        .get("required")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    parameters.insert(format!("{location}:{name}:required={required}"));
                }
            }
        }
        entry.insert(
            "parameters".to_string(),
            Value::Array(parameters.into_iter().map(Value::String).collect()),
        );

        let mut responses: BTreeSet<String> = BTreeSet::new();
        if let Some(map) = operation.get("responses").and_then(Value::as_object) {
            for status in map.keys() {
                responses.insert(status.clone());
            }
        }
        entry.insert(
            "responses".to_string(),
            Value::Array(responses.into_iter().map(Value::String).collect()),
        );

        if let Some(security) = operation.get("security") {
            entry.insert("security".to_string(), security.clone());
        }

        paths
            .entry(path)
            .or_default()
            .insert(method, Value::Object(entry));
    }

    json!({
        "info": {
            "version": spec.pointer("/info/version").cloned().unwrap_or(Value::Null),
        },
        "paths": paths,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn spec_is_valid_openapi_document() {
    let spec = load_spec();

    assert_eq!(
        spec.get("openapi").and_then(Value::as_str).map(|v| v.starts_with('3')),
        Some(true),
        "spec must declare OpenAPI 3.x"
    );

    let info = spec.get("info").expect("spec must contain `info`");
    assert!(
        info.get("version")
            .and_then(Value::as_str)
            .map(|v| !v.is_empty())
            .unwrap_or(false),
        "spec must declare a non-empty `info.version`"
    );
    assert!(
        info.get("title")
            .and_then(Value::as_str)
            .map(|v| !v.is_empty())
            .unwrap_or(false),
        "spec must declare a non-empty `info.title`"
    );

    // Every `$ref` must resolve.
    let mut refs = Vec::new();
    collect_refs(&spec, &mut refs);
    for reference in &refs {
        let _ = resolve_ref(&spec, reference);
    }

    // Operation ids must be present and unique.
    let mut seen_operation_ids = BTreeSet::new();
    for (path, method, operation) in operations(&spec) {
        let operation_id = operation
            .get("operationId")
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("{method} {path} is missing `operationId`"));
        assert!(
            seen_operation_ids.insert(operation_id.to_string()),
            "duplicate operationId `{operation_id}`"
        );
    }
}

#[test]
fn spec_documents_all_required_endpoint_groups() {
    let spec = load_spec();

    let mut documented_tags: BTreeSet<String> = BTreeSet::new();
    for (_, _, operation) in operations(&spec) {
        if let Some(tags) = operation.get("tags").and_then(Value::as_array) {
            for tag in tags {
                if let Some(tag) = tag.as_str() {
                    documented_tags.insert(tag.to_string());
                }
            }
        }
    }

    for required in REQUIRED_TAGS {
        assert!(
            documented_tags.contains(*required),
            "no endpoint is tagged `{required}`; contract must cover auth, tournament, \
             match, wallet, dispute and notification endpoints"
        );
    }
}

#[test]
fn every_operation_documents_auth_and_errors() {
    let spec = load_spec();

    for (path, method, operation) in operations(&spec) {
        let context = format!("{method} {path}");

        // Authentication: either the operation or the document declares a
        // security scheme. Public endpoints must opt out explicitly with an
        // empty security array.
        let has_security = operation.contains_key("security") || spec.contains_key("security");
        assert!(
            has_security,
            "{context}: must declare authentication requirements (or an explicit empty \
             `security` array for public endpoints)"
        );

        // Error codes: every operation must document at least one 4xx response.
        let responses = operation
            .get("responses")
            .and_then(Value::as_object)
            .unwrap_or_else(|| panic!("{context}: missing `responses`"));
        assert!(
            responses.keys().any(|status| status.starts_with('4')),
            "{context}: must document at least one 4xx error response"
        );
    }
}

#[test]
fn documented_examples_round_trip_through_handlers() {
    let spec = load_spec();

    let mut exercised = BTreeSet::new();

    for (path, method, operation) in operations(&spec) {
        let context = format!("{method} {path}");

        if let Some(example) = request_example(&operation) {
            let schema = request_schema(&operation)
                .unwrap_or_else(|| panic!("{context}: request example without schema"));
            assert_example_matches_schema(&spec, schema, &example, &format!("{context} request"));

            // Round-trip through the handler: the handler must accept the
            // documented request example and echo back a response that
            // conforms to the documented success schema.
            let response = openapi_spec::exercise_handler(&method, &path, Some(&example))
                .unwrap_or_else(|| panic!("{context}: handler returned no response"));

            if let Some(schema) = response_schema(&operation) {
                assert_example_matches_schema(
                    &spec,
                    schema,
                    &response,
                    &format!("{context} response"),
                );
            }

            if let Some(tags) = operation.get("tags").and_then(Value::as_array) {
                for tag in tags {
                    if let Some(tag) = tag.as_str() {
                        exercised.insert(tag.to_string());
                    }
                }
            }
        }

        if let Some(example) = response_example(&operation) {
            let schema = response_schema(&operation)
                .unwrap_or_else(|| panic!("{context}: response example without schema"));
            assert_example_matches_schema(&spec, schema, &example, &format!("{context} response"));
        }
    }

    for required in REQUIRED_TAGS {
        assert!(
            exercised.contains(*required),
            "no request example was exercised against a handler for `{required}` endpoints"
        );
    }
}

#[test]
fn contract_has_no_undetected_breaking_changes() {
    let spec = load_spec();
    let current = contract_fingerprint(&spec);
    let path = baseline_path();

    if std::env::var(UPDATE_BASELINE_ENV).is_ok() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create fixtures directory");
        }
        let serialized = serde_json::to_string_pretty(&current).expect("serialize fingerprint");
        fs::write(&path, serialized).expect("write baseline fixture");
        return;
    }

    let baseline_raw = fs::read_to_string(&path).unwrap_or_else(|err| {
        panic!(
            "missing API contract baseline at {}: {err}. Generate it with \
             `{UPDATE_BASELINE_ENV}=1 cargo test --test api_contract` after an explicit \
             version/deprecation decision.",
            path.display()
        )
    });
    let baseline: Value =
        serde_json::from_str(&baseline_raw).expect("baseline fixture must be valid JSON");

    if baseline == current {
        return;
    }

    let baseline_version = baseline
        .pointer("/info/version")
        .and_then(Value::as_str)
        .unwrap_or("<unknown>");
    let current_version = current
        .pointer("/info/version")
        .and_then(Value::as_str)
        .unwrap_or("<unknown>");

    assert_ne!(
        baseline_version, current_version,
        "API contract changed without a version bump. Breaking changes require an explicit \
         version/deprecation decision: bump `info.version` and regenerate the baseline with \
         `{UPDATE_BASELINE_ENV}=1 cargo test --test api_contract`.\n\n\
         baseline: {baseline}\n\ncurrent: {current}"
    );
}
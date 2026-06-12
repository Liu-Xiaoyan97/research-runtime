from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable


SCHEMA_DIR = Path("workflow/oh-my-autoresearch/schemas")


def load_schema(root: Path, schema_name: str) -> dict[str, Any]:
    schema_path = root / SCHEMA_DIR / schema_name
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing schema: {schema_path}") from exc

    if not isinstance(schema, dict) or not isinstance(schema.get("properties"), dict):
        raise SystemExit(f"Invalid schema: missing object properties in {schema_path}")

    return schema


def property_validator(schema: dict[str, Any], property_name: str) -> Callable[[Any], Any]:
    properties = schema.get("properties", {})
    if property_name not in properties:
        raise SystemExit(f"Invalid schema: missing property {property_name}")

    def validator(value: Any) -> Any:
        validate_json_schema(value, properties[property_name], schema, property_name)
        return value

    return validator


def validate_against_schema(value: Any, schema: dict[str, Any], location: str = "$") -> Any:
    validate_json_schema(value, schema, schema, location)
    return value


def validate_json_schema(
    value: Any,
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    location: str,
) -> None:
    if "$ref" in schema:
        schema = resolve_schema_ref(schema["$ref"], root_schema)

    expected_type = schema.get("type")
    if expected_type is not None and not matches_schema_type(value, expected_type):
        raise ValueError(f"{location} must be {format_schema_type(expected_type)}")

    if "const" in schema and value != schema["const"]:
        raise ValueError(f"{location} must be {schema['const']!r}")

    if "enum" in schema and value not in schema["enum"]:
        raise ValueError(f"{location} must be one of {schema['enum']!r}")

    if isinstance(value, str) and "minLength" in schema and len(value) < schema["minLength"]:
        raise ValueError(f"{location} must have length >= {schema['minLength']}")

    if isinstance(value, (int, float)) and not isinstance(value, bool) and "minimum" in schema:
        if value < schema["minimum"]:
            raise ValueError(f"{location} must be >= {schema['minimum']}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise ValueError(f"{location} must have at least {schema['minItems']} items")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for idx, item in enumerate(value):
                validate_json_schema(item, item_schema, root_schema, f"{location}[{idx}]")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                raise ValueError(f"{location} missing {key}")

        properties = schema.get("properties", {})
        if isinstance(properties, dict):
            for key, child_value in value.items():
                child_schema = properties.get(key)
                if isinstance(child_schema, dict):
                    validate_json_schema(child_value, child_schema, root_schema, f"{location}.{key}")
                elif schema.get("additionalProperties") is False:
                    raise ValueError(f"{location} has unexpected property {key}")


def resolve_schema_ref(ref: str, root_schema: dict[str, Any]) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValueError(f"Unsupported schema ref: {ref}")

    node: Any = root_schema
    for part in ref[2:].split("/"):
        if not isinstance(node, dict) or part not in node:
            raise ValueError(f"Unresolved schema ref: {ref}")
        node = node[part]

    if not isinstance(node, dict):
        raise ValueError(f"Schema ref does not point to an object: {ref}")
    return node


def matches_schema_type(value: Any, expected_type: str | list[str]) -> bool:
    if isinstance(expected_type, list):
        return any(matches_schema_type(value, item) for item in expected_type)

    if expected_type == "object":
        return isinstance(value, dict)
    if expected_type == "array":
        return isinstance(value, list)
    if expected_type == "string":
        return isinstance(value, str)
    if expected_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected_type == "boolean":
        return isinstance(value, bool)
    if expected_type == "null":
        return value is None
    raise ValueError(f"Unsupported schema type: {expected_type}")


def format_schema_type(expected_type: str | list[str]) -> str:
    if isinstance(expected_type, list):
        return " or ".join(expected_type)
    return expected_type

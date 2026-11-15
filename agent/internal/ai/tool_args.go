//go:build linux || windows

package ai

import (
	"encoding/json"
	"fmt"
	"math"
)

// Validate the subset of JSON Schema used by our tool catalog before executing.
// In particular, an omitted content/newString must never mean "delete content".
func validateToolArgs(value any, schema map[string]any, path string) error {
	valid := false
	switch schema["type"] {
	case "object":
		object, ok := value.(map[string]any)
		valid = ok && object != nil
		if !valid {
			break
		}
		for _, key := range stringList(schema["required"]) {
			if _, ok := object[key]; !ok {
				return fmt.Errorf("%s.%s is required", path, key)
			}
		}
		props, _ := schema["properties"].(map[string]any)
		for key, item := range object {
			if child, ok := props[key].(map[string]any); ok {
				if err := validateToolArgs(item, child, path+"."+key); err != nil {
					return err
				}
			}
		}
	case "array":
		list, ok := value.([]any)
		valid = ok && list != nil
		if valid {
			if min, ok := schema["minItems"].(int); ok && len(list) < min {
				return fmt.Errorf("%s needs at least %d items", path, min)
			}
			if max, ok := schema["maxItems"].(int); ok && len(list) > max {
				return fmt.Errorf("%s allows at most %d items", path, max)
			}
			if child, ok := schema["items"].(map[string]any); ok {
				for i, item := range list {
					if err := validateToolArgs(item, child, fmt.Sprintf("%s[%d]", path, i)); err != nil {
						return err
					}
				}
			}
		}
	case "string":
		text, ok := value.(string)
		valid = ok
		if choices := stringList(schema["enum"]); ok && len(choices) > 0 {
			valid = false
			for _, choice := range choices {
				valid = valid || text == choice
			}
		}
	case "boolean":
		_, valid = value.(bool)
	case "integer":
		number, ok := value.(float64)
		valid = ok && number == math.Trunc(number)
	case "number":
		_, valid = value.(float64)
	default:
		return nil
	}
	if !valid {
		return fmt.Errorf("%s must match the declared %s schema", path, schema["type"])
	}
	return nil
}

func stringList(value any) []string {
	if list, ok := value.([]string); ok {
		return list
	}
	var out []string
	if list, ok := value.([]any); ok {
		for _, item := range list {
			if text, ok := item.(string); ok {
				out = append(out, text)
			}
		}
	}
	return out
}

func decodeToolArgs(raw json.RawMessage, def ToolDef) error {
	var args map[string]any
	if len(raw) > 2<<20 || json.Unmarshal(raw, &args) != nil || args == nil {
		return fmt.Errorf("tool arguments must be a JSON object of at most 2 MiB")
	}
	// Keep the established filePath alias while advertising one canonical path.
	if _, set := args["path"]; !set && (def.Name == "read" || def.Name == "write" || def.Name == "edit") {
		if alias, ok := args["filePath"]; ok {
			args["path"] = alias
		}
	}
	return validateToolArgs(args, def.Parameters, "arguments")
}

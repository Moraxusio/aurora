package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
)

// streamAnthropicMessages ports OpenCode's anthropic-messages protocol
// (packages/ai/src/protocols/anthropic-messages.ts), including ephemeral prompt-cache
// breakpoints, interleaved thinking + signatures, redacted_thinking, and tool_use / tool_result blocks.
func streamAnthropicMessages(ctx context.Context, req LLMRequest, proxyEnv func() map[string]string, onDelta func(LLMDelta)) (LLMResponse, error) {
	endpoint := resolveEndpoint(req.Provider.BaseURL, "https://api.anthropic.com/v1", "/messages")

	// System blocks (up to 2 cache breakpoints on system, matching OpenCode)
	var systemBlocks []map[string]any
	for i, s := range req.System {
		if strings.TrimSpace(s) == "" {
			continue
		}
		blk := map[string]any{
			"type": "text",
			"text": s,
		}
		if i == len(req.System)-1 {
			blk["cache_control"] = map[string]string{"type": "ephemeral"}
		}
		systemBlocks = append(systemBlocks, blk)
	}

	// Lower messages with strict alternating user/assistant turns required by Anthropic Messages
	type anthMsg struct {
		Role    string           `json:"role"`
		Content []map[string]any `json:"content"`
	}
	var messages []anthMsg

	appendTurn := func(role string, blocks ...map[string]any) {
		if len(blocks) == 0 {
			return
		}
		if len(messages) > 0 && messages[len(messages)-1].Role == role {
			messages[len(messages)-1].Content = append(messages[len(messages)-1].Content, blocks...)
			return
		}
		messages = append(messages, anthMsg{
			Role:    role,
			Content: append([]map[string]any(nil), blocks...),
		})
	}

	thinkingEnabled := req.Provider.ReasoningEffort != ""
	hasInterleavedThinking := false

	for _, msg := range req.Messages {
		switch msg.Role {
		case "user":
			var blocks []map[string]any
			for _, p := range msg.Parts {
				if p.DataURL != "" {
					_, data, _ := strings.Cut(p.DataURL, ",")
					typ := "document"
					if p.Type == "image" {
						typ = "image"
					}
					blocks = append(blocks, map[string]any{"type": typ, "source": map[string]any{"type": "base64", "media_type": p.Mime, "data": data}})
				}
				if p.Type == "text" && p.Text != "" {
					blocks = append(blocks, map[string]any{
						"type": "text",
						"text": p.Text,
					})
				}
			}
			appendTurn("user", blocks...)

		case "assistant":
			var asstBlocks []map[string]any
			var userToolResults []map[string]any
			sawToolUse := false
			sawThinking := false

			for _, p := range msg.Parts {
				switch p.Type {
				case "reasoning":
					// Anthropic requires cryptographic signatures when replaying thinking blocks.
					// If switching from another provider without signature, downgrade to plain text or skip if empty.
					if p.Redacted != "" {
						asstBlocks = append(asstBlocks, map[string]any{
							"type": "redacted_thinking",
							"data": p.Redacted,
						})
						sawThinking = true
					} else if p.Signature != "" && p.Text != "" {
						asstBlocks = append(asstBlocks, map[string]any{
							"type":      "thinking",
							"thinking":  p.Text,
							"signature": p.Signature,
						})
						sawThinking = true
					}
				case "text":
					if p.Text != "" {
						asstBlocks = append(asstBlocks, map[string]any{
							"type": "text",
							"text": p.Text,
						})
					}
				case "tool-call":
					var inputObj any = map[string]any{}
					if len(p.Input) > 0 {
						_ = json.Unmarshal(p.Input, &inputObj)
					}
					if _, ok := inputObj.(map[string]any); !ok {
						inputObj = map[string]any{}
					}
					asstBlocks = append(asstBlocks, map[string]any{
						"type":  "tool_use",
						"id":    p.ToolCallID,
						"name":  p.ToolName,
						"input": inputObj,
					})
					sawToolUse = true
				case "tool-result":
					tr := map[string]any{
						"type":        "tool_result",
						"tool_use_id": p.ToolCallID,
						"content":     p.Output,
					}
					if p.IsError {
						tr["is_error"] = true
					}
					userToolResults = append(userToolResults, tr)
				}
			}
			if sawThinking && sawToolUse {
				hasInterleavedThinking = true
			}
			appendTurn("assistant", asstBlocks...)
			appendTurn("user", userToolResults...)

		case "tool":
			var blocks []map[string]any
			for _, p := range msg.Parts {
				if p.Type == "tool-result" {
					tr := map[string]any{
						"type":        "tool_result",
						"tool_use_id": p.ToolCallID,
						"content":     p.Output,
					}
					if p.IsError {
						tr["is_error"] = true
					}
					blocks = append(blocks, tr)
				}
			}
			appendTurn("user", blocks...)
		}
	}

	// Place ephemeral cache_control breakpoint on the last block of the latest user turn (matching OpenCode)
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Role == "user" && len(messages[i].Content) > 0 {
			lastBlk := messages[i].Content[len(messages[i].Content)-1]
			lastBlk["cache_control"] = map[string]string{"type": "ephemeral"}
			break
		}
	}

	maxTok := req.MaxTokens
	if maxTok <= 0 {
		maxTok = req.Provider.MaxOutputTokens
	}
	if maxTok <= 0 {
		maxTok = 16384
	}

	body := map[string]any{
		"model":      req.Provider.Model,
		"max_tokens": maxTok,
		"messages":   messages,
		"stream":     true,
	}
	if len(systemBlocks) > 0 {
		body["system"] = systemBlocks
	}

	if len(req.Tools) > 0 {
		toolsPayload := make([]map[string]any, 0, len(req.Tools))
		for i, t := range req.Tools {
			tb := map[string]any{
				"name":         t.Name,
				"description":  t.Description,
				"input_schema": t.Parameters,
			}
			if i == len(req.Tools)-1 {
				tb["cache_control"] = map[string]string{"type": "ephemeral"}
			}
			toolsPayload = append(toolsPayload, tb)
		}
		body["tools"] = toolsPayload
	}

	if thinkingEnabled {
		budget := 4096
		switch req.Provider.ReasoningEffort {
		case "low":
			budget = 2048
		case "medium":
			budget = 8192
		case "high":
			budget = 16000
		}
		if maxTok <= budget {
			maxTok = budget + 4096
			body["max_tokens"] = maxTok
		}
		body["thinking"] = map[string]any{
			"type":          "enabled",
			"budget_tokens": budget,
		}
		hasInterleavedThinking = true
	} else if req.Temperature != nil {
		body["temperature"] = *req.Temperature
	}

	rawBody, err := json.Marshal(body)
	if err != nil {
		return LLMResponse{}, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(rawBody))
	if err != nil {
		return LLMResponse{}, err
	}
	applyOpenCodeHeaders(httpReq.Header, req)
	if httpReq.Header.Get("anthropic-version") == "" {
		httpReq.Header.Set("anthropic-version", "2023-06-01")
	}
	// Beta headers matching OpenCode's requiredBetaHeaders
	var betas []string
	if existing := httpReq.Header.Get("anthropic-beta"); existing != "" {
		for _, b := range strings.Split(existing, ",") {
			if b = strings.TrimSpace(b); b != "" {
				betas = append(betas, b)
			}
		}
	}
	if hasInterleavedThinking {
		betas = appendUnique(betas, "interleaved-thinking-2025-05-14")
	}
	if len(betas) > 0 {
		httpReq.Header.Set("anthropic-beta", strings.Join(betas, ","))
	}

	client := newHTTPClient(req.Provider.UseProxy, proxyEnv, req.Provider.ProxyMode)
	res, err := client.Do(httpReq)
	if err != nil {
		return LLMResponse{}, err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		errBody, _ := io.ReadAll(io.LimitReader(res.Body, 256*1024))
		return LLMResponse{}, &HTTPStatusError{Status: res.StatusCode, Body: string(errBody)}
	}

	type contentBlock struct {
		index     int
		blockType string // "text" | "thinking" | "redacted_thinking" | "tool_use"
		id        string
		name      string
		text      strings.Builder
		signature strings.Builder
		redacted  string
		inputJSON strings.Builder
		seedInput json.RawMessage
	}

	blocks := map[int]*contentBlock{}
	var usage Usage
	finishReason := "stop"

	err = readSSE(res.Body, func(ev sseEvent) error {
		data := strings.TrimSpace(ev.Data)
		if data == "" || data == "[DONE]" {
			return nil
		}
		var packet struct {
			Type    string `json:"type"`
			Index   int    `json:"index"`
			Message *struct {
				Usage *anthUsage `json:"usage"`
			} `json:"message"`
			ContentBlock *struct {
				Type     string          `json:"type"`
				ID       string          `json:"id"`
				Name     string          `json:"name"`
				Text     string          `json:"text"`
				Thinking string          `json:"thinking"`
				Data     string          `json:"data"`
				Input    json.RawMessage `json:"input"`
			} `json:"content_block"`
			Delta *struct {
				Type        string `json:"type"`
				Text        string `json:"text"`
				Thinking    string `json:"thinking"`
				Signature   string `json:"signature"`
				PartialJSON string `json:"partial_json"`
				StopReason  string `json:"stop_reason"`
			} `json:"delta"`
			Usage *anthUsage `json:"usage"`
			Error *struct {
				Type    string `json:"type"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if jerr := json.Unmarshal([]byte(data), &packet); jerr != nil {
			return nil
		}

		evType := packet.Type
		if evType == "" {
			evType = ev.Event
		}

		switch evType {
		case "error":
			return &HTTPStatusError{Status: 500, Body: data}

		case "message_start":
			if packet.Message != nil && packet.Message.Usage != nil {
				usage = mergeAnthUsage(usage, *packet.Message.Usage)
			}

		case "content_block_start":
			if packet.ContentBlock == nil {
				return nil
			}
			cb := &contentBlock{
				index:     packet.Index,
				blockType: packet.ContentBlock.Type,
				id:        packet.ContentBlock.ID,
				name:      packet.ContentBlock.Name,
				redacted:  packet.ContentBlock.Data,
			}
			if packet.ContentBlock.Text != "" {
				cb.text.WriteString(packet.ContentBlock.Text)
				if onDelta != nil {
					onDelta(LLMDelta{Type: "text", Text: packet.ContentBlock.Text})
				}
			}
			if packet.ContentBlock.Thinking != "" {
				cb.text.WriteString(packet.ContentBlock.Thinking)
				if onDelta != nil {
					onDelta(LLMDelta{Type: "reasoning", Text: packet.ContentBlock.Thinking})
				}
			}
			if len(packet.ContentBlock.Input) > 0 && string(packet.ContentBlock.Input) != "{}" && string(packet.ContentBlock.Input) != "null" {
				cb.seedInput = packet.ContentBlock.Input
			}
			if cb.blockType == "tool_use" && onDelta != nil {
				onDelta(LLMDelta{
					Type:       "tool-call-start",
					ToolCallID: cb.id,
					ToolName:   cb.name,
				})
			}
			blocks[packet.Index] = cb

		case "content_block_delta":
			if packet.Delta == nil {
				return nil
			}
			cb := blocks[packet.Index]
			if cb == nil {
				cb = &contentBlock{index: packet.Index}
				blocks[packet.Index] = cb
			}
			switch packet.Delta.Type {
			case "text_delta":
				if cb.blockType == "" {
					cb.blockType = "text"
				}
				cb.text.WriteString(packet.Delta.Text)
				if onDelta != nil && packet.Delta.Text != "" {
					onDelta(LLMDelta{Type: "text", Text: packet.Delta.Text})
				}
			case "thinking_delta":
				if cb.blockType == "" {
					cb.blockType = "thinking"
				}
				cb.text.WriteString(packet.Delta.Thinking)
				if onDelta != nil && packet.Delta.Thinking != "" {
					onDelta(LLMDelta{Type: "reasoning", Text: packet.Delta.Thinking})
				}
			case "signature_delta":
				cb.signature.WriteString(packet.Delta.Signature)
			case "input_json_delta":
				if cb.blockType == "" {
					cb.blockType = "tool_use"
				}
				cb.inputJSON.WriteString(packet.Delta.PartialJSON)
			}

		case "message_delta":
			if packet.Delta != nil && packet.Delta.StopReason != "" {
				finishReason = mapAnthropicStopReason(packet.Delta.StopReason)
			}
			if packet.Usage != nil {
				usage = mergeAnthUsage(usage, *packet.Usage)
			}

		case "message_stop":
			return errSSEStreamDone
		}
		return nil
	})
	if err != nil && !errors.Is(err, errSSEStreamDone) {
		return LLMResponse{}, err
	}

	var indices []int
	for k := range blocks {
		indices = append(indices, k)
	}
	sort.Ints(indices)

	var parts []Part
	hasToolCalls := false
	for _, idx := range indices {
		cb := blocks[idx]
		switch cb.blockType {
		case "thinking":
			parts = append(parts, Part{
				Type:      "reasoning",
				ID:        NewID("prt"),
				Text:      cb.text.String(),
				Signature: cb.signature.String(),
			})
		case "redacted_thinking":
			parts = append(parts, Part{
				Type:     "reasoning",
				ID:       NewID("prt"),
				Redacted: cb.redacted,
			})
		case "text":
			if cb.text.Len() > 0 {
				parts = append(parts, Part{
					Type: "text",
					ID:   NewID("prt"),
					Text: cb.text.String(),
				})
			}
		case "tool_use":
			rawArgs := strings.TrimSpace(cb.inputJSON.String())
			if rawArgs == "" && len(cb.seedInput) > 0 {
				rawArgs = string(cb.seedInput)
			}
			if rawArgs == "" || !json.Valid([]byte(rawArgs)) {
				rawArgs = "{}"
			}
			id := cb.id
			if id == "" {
				id = NewID("toolu")
			}
			parts = append(parts, Part{
				Type:       "tool-call",
				ID:         NewID("prt"),
				ToolCallID: id,
				ToolName:   cb.name,
				Input:      json.RawMessage(rawArgs),
			})
			hasToolCalls = true
			if onDelta != nil {
				onDelta(LLMDelta{
					Type:       "tool-call-end",
					ToolCallID: id,
					ToolName:   cb.name,
					ToolInput:  json.RawMessage(rawArgs),
				})
			}
		}
	}
	if hasToolCalls {
		finishReason = "tool-calls"
	}
	return LLMResponse{
		Parts:  parts,
		Finish: finishReason,
		Usage:  usage,
	}, nil
}

type anthUsage struct {
	InputTokens              *int `json:"input_tokens"`
	OutputTokens             *int `json:"output_tokens"`
	CacheCreationInputTokens *int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     *int `json:"cache_read_input_tokens"`
}

func mergeAnthUsage(prev Usage, u anthUsage) Usage {
	nonCached := prev.NonCachedInputTokens
	if u.InputTokens != nil {
		nonCached = *u.InputTokens
	}
	cacheRead := prev.CacheReadTokens
	if u.CacheReadInputTokens != nil {
		cacheRead = *u.CacheReadInputTokens
	}
	cacheWrite := prev.CacheWriteTokens
	if u.CacheCreationInputTokens != nil {
		cacheWrite = *u.CacheCreationInputTokens
	}
	outTok := prev.OutputTokens
	if u.OutputTokens != nil {
		outTok = *u.OutputTokens
	}
	inTotal := nonCached + cacheRead + cacheWrite
	return Usage{
		InputTokens:          inTotal,
		OutputTokens:         outTok,
		NonCachedInputTokens: nonCached,
		CacheReadTokens:      cacheRead,
		CacheWriteTokens:     cacheWrite,
		TotalTokens:          inTotal + outTok,
	}
}

func mapAnthropicStopReason(r string) string {
	switch r {
	case "tool_use":
		return "tool-calls"
	case "max_tokens", "model_context_window_exceeded":
		return "length"
	case "refusal":
		return "content-filter"
	default:
		return "stop"
	}
}

func appendUnique(list []string, item string) []string {
	for _, x := range list {
		if strings.EqualFold(x, item) {
			return list
		}
	}
	return append(list, item)
}

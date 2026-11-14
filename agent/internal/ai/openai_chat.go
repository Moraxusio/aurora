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

// streamOpenAIChat ports OpenCode's openai-chat protocol (packages/ai/src/protocols/openai-chat.ts).
// Supports OpenAI, OpenRouter, DeepSeek, Qwen, GLM/Z.ai, Moonshot/Kimi, MiniMax, SiliconFlow, and OpenCode Zen gateways.
func streamOpenAIChat(ctx context.Context, req LLMRequest, proxyEnv func() map[string]string, onDelta func(LLMDelta)) (LLMResponse, error) {
	endpoint := resolveEndpoint(req.Provider.BaseURL, "https://api.openai.com/v1", "/chat/completions")
	isOpenRouter := strings.Contains(strings.ToLower(endpoint), "openrouter.ai")
	isAnthropicModel := strings.Contains(strings.ToLower(req.Provider.Model), "claude")

	var messages []map[string]any
	if len(req.System) > 0 {
		sysText := strings.Join(req.System, "\n\n")
		if isOpenRouter && isAnthropicModel {
			messages = append(messages, map[string]any{
				"role": "system",
				"content": []map[string]any{
					{
						"type":          "text",
						"text":          sysText,
						"cache_control": map[string]string{"type": "ephemeral"},
					},
				},
			})
		} else {
			messages = append(messages, map[string]any{
				"role":    "system",
				"content": sysText,
			})
		}
	}

	// Discover if previous assistant messages recorded a specific reasoning field (e.g. DeepSeek/Moonshot "reasoning_content")
	defaultReasoningField := ""
	modelLower := strings.ToLower(req.Provider.Model)
	if strings.Contains(modelLower, "deepseek") || strings.Contains(modelLower, "kimi") || strings.Contains(modelLower, "moonshot") || strings.Contains(modelLower, "glm") || strings.Contains(modelLower, "qwq") {
		defaultReasoningField = "reasoning_content"
	}

	for _, msg := range req.Messages {
		switch msg.Role {
		case "user":
			var texts []string
			var media []map[string]any
			for _, p := range msg.Parts {
				if p.DataURL != "" {
					if p.Type == "image" {
						media = append(media, map[string]any{"type": "image_url", "image_url": map[string]any{"url": p.DataURL}})
					} else {
						media = append(media, map[string]any{"type": "file", "file": map[string]any{"filename": p.Filename, "file_data": p.DataURL}})
					}
				}
				if p.Type == "text" && p.Text != "" {
					texts = append(texts, p.Text)
				}
			}
			if len(media) > 0 {
				if len(texts) > 0 {
					media = append([]map[string]any{{"type": "text", "text": strings.Join(texts, "\n\n")}}, media...)
				}
				messages = append(messages, map[string]any{"role": "user", "content": media})
			} else if len(texts) > 0 {
				messages = append(messages, map[string]any{
					"role":    "user",
					"content": strings.Join(texts, "\n\n"),
				})
			}

		case "assistant":
			var texts []string
			var reasonings []string
			rField := defaultReasoningField
			var toolCalls []map[string]any
			var toolResults []Part

			for _, p := range msg.Parts {
				switch p.Type {
				case "text":
					if p.Text != "" {
						texts = append(texts, p.Text)
					}
				case "reasoning":
					if p.Text != "" {
						reasonings = append(reasonings, p.Text)
					}
					if f, ok := p.ProviderMeta["reasoningField"].(string); ok && f != "" {
						rField = f
					}
				case "tool-call":
					argsStr := string(p.Input)
					if strings.TrimSpace(argsStr) == "" {
						argsStr = "{}"
					}
					tc := map[string]any{
						"id":   p.ToolCallID,
						"type": "function",
						"function": map[string]any{
							"name":      p.ToolName,
							"arguments": argsStr,
						},
					}
					if ec, ok := p.ProviderMeta["extra_content"]; ok && ec != nil {
						tc["extra_content"] = ec
					}
					toolCalls = append(toolCalls, tc)
				case "tool-result":
					toolResults = append(toolResults, p)
				}
			}

			if len(texts) > 0 || len(toolCalls) > 0 || len(reasonings) > 0 {
				am := map[string]any{
					"role": "assistant",
				}
				if len(texts) > 0 {
					am["content"] = strings.Join(texts, "")
				} else if len(toolCalls) > 0 {
					am["content"] = nil
				} else {
					am["content"] = ""
				}
				if len(reasonings) > 0 && rField != "" {
					am[rField] = strings.Join(reasonings, "")
				} else if len(toolCalls) > 0 && defaultReasoningField == "reasoning_content" {
					// DeepSeek / Kimi thinking mode requires reasoning_content string on assistant tool-call turns
					am["reasoning_content"] = strings.Join(reasonings, "")
				}
				if len(toolCalls) > 0 {
					am["tool_calls"] = toolCalls
				}
				messages = append(messages, am)
			}
			for _, tr := range toolResults {
				messages = append(messages, map[string]any{
					"role":         "tool",
					"tool_call_id": tr.ToolCallID,
					"content":      tr.Output,
				})
			}

		case "tool":
			for _, tr := range msg.Parts {
				if tr.Type == "tool-result" {
					messages = append(messages, map[string]any{
						"role":         "tool",
						"tool_call_id": tr.ToolCallID,
						"content":      tr.Output,
					})
				}
			}
		}
	}

	body := map[string]any{
		"model":    req.Provider.Model,
		"messages": messages,
		"stream":   true,
		"stream_options": map[string]any{
			"include_usage": true,
		},
	}

	if len(req.Tools) > 0 {
		toolsPayload := make([]map[string]any, 0, len(req.Tools))
		for _, t := range req.Tools {
			toolsPayload = append(toolsPayload, map[string]any{
				"type": "function",
				"function": map[string]any{
					"name":        t.Name,
					"description": t.Description,
					"parameters":  t.Parameters,
				},
			})
		}
		body["tools"] = toolsPayload
	}

	maxTok := req.MaxTokens
	if maxTok <= 0 {
		maxTok = req.Provider.MaxOutputTokens
	}
	if maxTok > 0 {
		if strings.HasPrefix(modelLower, "o1") || strings.HasPrefix(modelLower, "o3") || strings.HasPrefix(modelLower, "o4") || strings.HasPrefix(modelLower, "gpt-5") {
			body["max_completion_tokens"] = maxTok
		} else {
			body["max_tokens"] = maxTok
		}
	}
	if req.Provider.ReasoningEffort != "" {
		body["reasoning_effort"] = req.Provider.ReasoningEffort
	}
	if req.Temperature != nil && req.Provider.ReasoningEffort == "" {
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

	type toolAccum struct {
		index        int
		id           string
		name         string
		args         strings.Builder
		extraContent any
		started      bool
	}

	var textBuf strings.Builder
	var reasoningBuf strings.Builder
	observedReasoningField := ""
	toolsByIdx := map[int]*toolAccum{}
	latestToolIdx := -1
	nextToolIdx := 0
	var usage Usage
	finishReason := ""

	err = readSSE(res.Body, func(ev sseEvent) error {
		data := strings.TrimSpace(ev.Data)
		if data == "" {
			return nil
		}
		if data == "[DONE]" {
			return errSSEStreamDone
		}

		var chunk struct {
			Error *struct {
				Message string `json:"message"`
				Type    string `json:"type"`
				Code    any    `json:"code"`
			} `json:"error"`
			Choices []struct {
				FinishReason string          `json:"finish_reason"`
				Delta        json.RawMessage `json:"delta"`
				Usage        json.RawMessage `json:"usage"`
			} `json:"choices"`
			Usage json.RawMessage `json:"usage"`
		}
		if jerr := json.Unmarshal([]byte(data), &chunk); jerr != nil {
			// Tolerate non-JSON keepalive frames from gateways
			return nil
		}
		if chunk.Error != nil && (chunk.Error.Message != "" || chunk.Error.Type != "") {
			return &HTTPStatusError{Status: 500, Body: data}
		}

		if len(chunk.Usage) > 0 && string(chunk.Usage) != "null" {
			if u, ok := parseOpenAIUsage(chunk.Usage); ok {
				usage = u
			}
		}

		if len(chunk.Choices) == 0 {
			return nil
		}
		choice := chunk.Choices[0]
		if len(choice.Usage) > 0 && string(choice.Usage) != "null" {
			if u, ok := parseOpenAIUsage(choice.Usage); ok {
				usage = u
			}
		}
		if choice.FinishReason != "" {
			finishReason = mapOpenAIFinishReason(choice.FinishReason)
		}
		if len(choice.Delta) == 0 || string(choice.Delta) == "null" {
			return nil
		}

		var delta struct {
			Content          string `json:"content"`
			Refusal          string `json:"refusal"`
			ReasoningContent string `json:"reasoning_content"`
			Reasoning        string `json:"reasoning"`
			ReasoningText    string `json:"reasoning_text"`
			ReasoningDetails []struct {
				Type    string `json:"type"`
				Text    string `json:"text"`
				Summary string `json:"summary"`
			} `json:"reasoning_details"`
			ToolCalls []struct {
				Index    *int   `json:"index"`
				ID       string `json:"id"`
				Type     string `json:"type"`
				Function struct {
					Name      string `json:"name"`
					Arguments string `json:"arguments"`
				} `json:"function"`
				ExtraContent any `json:"extra_content"`
			} `json:"tool_calls"`
		}
		if err := json.Unmarshal(choice.Delta, &delta); err != nil {
			return nil
		}

		// Extract reasoning across compatible fields (matching OpenCode's reasoningDelta + reasoning_details)
		rDelta := ""
		if delta.ReasoningContent != "" {
			rDelta = delta.ReasoningContent
			if observedReasoningField == "" {
				observedReasoningField = "reasoning_content"
			}
		} else if delta.Reasoning != "" {
			rDelta = delta.Reasoning
			if observedReasoningField == "" {
				observedReasoningField = "reasoning"
			}
		} else if delta.ReasoningText != "" {
			rDelta = delta.ReasoningText
			if observedReasoningField == "" {
				observedReasoningField = "reasoning_text"
			}
		} else if len(delta.ReasoningDetails) > 0 {
			var parts []string
			for _, d := range delta.ReasoningDetails {
				if d.Text != "" {
					parts = append(parts, d.Text)
				} else if d.Summary != "" {
					parts = append(parts, d.Summary)
				}
			}
			rDelta = strings.Join(parts, "")
		}

		if rDelta != "" {
			reasoningBuf.WriteString(rDelta)
			if onDelta != nil {
				onDelta(LLMDelta{Type: "reasoning", Text: rDelta})
			}
		}

		cDelta := delta.Content
		if cDelta == "" && delta.Refusal != "" {
			cDelta = delta.Refusal
		}
		if cDelta != "" {
			textBuf.WriteString(cDelta)
			if onDelta != nil {
				onDelta(LLMDelta{Type: "text", Text: cDelta})
			}
		}

		for pos, tc := range delta.ToolCalls {
			idx := -1
			if tc.Index != nil {
				idx = *tc.Index
			} else if tc.ID != "" {
				for k, existing := range toolsByIdx {
					if existing.id == tc.ID {
						idx = k
						break
					}
				}
				if idx < 0 {
					idx = nextToolIdx
				}
			} else if latestToolIdx >= 0 && len(delta.ToolCalls) == 1 {
				idx = latestToolIdx
			} else {
				idx = pos
			}
			latestToolIdx = idx
			if idx+1 > nextToolIdx {
				nextToolIdx = idx + 1
			}

			acc, ok := toolsByIdx[idx]
			if !ok {
				acc = &toolAccum{index: idx}
				toolsByIdx[idx] = acc
			}
			if tc.ID != "" && acc.id == "" {
				acc.id = tc.ID
			}
			if tc.Function.Name != "" && acc.name == "" {
				acc.name = tc.Function.Name
			}
			if tc.ExtraContent != nil && acc.extraContent == nil {
				acc.extraContent = tc.ExtraContent
			}
			if tc.Function.Arguments != "" {
				acc.args.WriteString(tc.Function.Arguments)
			}
			if !acc.started && acc.id != "" && acc.name != "" {
				acc.started = true
				if onDelta != nil {
					onDelta(LLMDelta{
						Type:       "tool-call-start",
						ToolCallID: acc.id,
						ToolName:   acc.name,
					})
				}
			}
		}
		return nil
	})
	if err != nil && !errors.Is(err, errSSEStreamDone) {
		return LLMResponse{}, err
	}

	var parts []Part
	if reasoningBuf.Len() > 0 {
		p := Part{
			Type: "reasoning",
			ID:   NewID("prt"),
			Text: reasoningBuf.String(),
		}
		if observedReasoningField != "" {
			p.ProviderMeta = map[string]any{"reasoningField": observedReasoningField}
		}
		parts = append(parts, p)
	}
	if textBuf.Len() > 0 {
		parts = append(parts, Part{
			Type: "text",
			ID:   NewID("prt"),
			Text: textBuf.String(),
		})
	}

	var idxs []int
	for k := range toolsByIdx {
		idxs = append(idxs, k)
	}
	sort.Ints(idxs)
	hasToolCalls := false
	for _, k := range idxs {
		acc := toolsByIdx[k]
		if acc.name == "" {
			continue
		}
		if acc.id == "" {
			acc.id = NewID("call")
		}
		rawArgs := strings.TrimSpace(acc.args.String())
		if rawArgs == "" || !json.Valid([]byte(rawArgs)) {
			if rawArgs == "" {
				rawArgs = "{}"
			} else {
				// Wrap malformed JSON so replay remains valid JSON
				b, _ := json.Marshal(map[string]string{"_raw": rawArgs})
				rawArgs = string(b)
			}
		}
		var meta map[string]any
		if acc.extraContent != nil {
			meta = map[string]any{"extra_content": acc.extraContent}
		}
		parts = append(parts, Part{
			Type:         "tool-call",
			ID:           NewID("prt"),
			ToolCallID:   acc.id,
			ToolName:     acc.name,
			Input:        json.RawMessage(rawArgs),
			ProviderMeta: meta,
		})
		hasToolCalls = true
		if onDelta != nil {
			onDelta(LLMDelta{
				Type:       "tool-call-end",
				ToolCallID: acc.id,
				ToolName:   acc.name,
				ToolInput:  json.RawMessage(rawArgs),
			})
		}
	}

	if hasToolCalls {
		finishReason = "tool-calls"
	} else if finishReason == "" {
		finishReason = "stop"
	}

	return LLMResponse{
		Parts:  parts,
		Finish: finishReason,
		Usage:  usage,
	}, nil
}

func mapOpenAIFinishReason(raw string) string {
	switch raw {
	case "stop":
		return "stop"
	case "tool_calls", "function_call":
		return "tool-calls"
	case "length":
		return "length"
	case "content_filter":
		return "content-filter"
	default:
		return "stop"
	}
}

func parseOpenAIUsage(raw json.RawMessage) (Usage, bool) {
	var u struct {
		PromptTokens        int     `json:"prompt_tokens"`
		CompletionTokens    int     `json:"completion_tokens"`
		TotalTokens         int     `json:"total_tokens"`
		Cost                float64 `json:"cost"`
		PromptTokensDetails *struct {
			CachedTokens     int `json:"cached_tokens"`
			CacheWriteTokens int `json:"cache_write_tokens"`
		} `json:"prompt_tokens_details"`
		CompletionTokensDetails *struct {
			ReasoningTokens int `json:"reasoning_tokens"`
		} `json:"completion_tokens_details"`
		PromptCacheHitTokens int `json:"prompt_cache_hit_tokens"` // DeepSeek
	}
	if err := json.Unmarshal(raw, &u); err != nil {
		return Usage{}, false
	}
	if u.PromptTokens == 0 && u.CompletionTokens == 0 && u.TotalTokens == 0 {
		return Usage{}, false
	}
	cached := u.PromptCacheHitTokens
	cacheWrite := 0
	if u.PromptTokensDetails != nil {
		if u.PromptTokensDetails.CachedTokens > cached {
			cached = u.PromptTokensDetails.CachedTokens
		}
		cacheWrite = u.PromptTokensDetails.CacheWriteTokens
	}
	reasoning := 0
	if u.CompletionTokensDetails != nil {
		reasoning = u.CompletionTokensDetails.ReasoningTokens
	}
	nonCached := u.PromptTokens - cached - cacheWrite
	if nonCached < 0 {
		nonCached = 0
	}
	tot := u.TotalTokens
	if tot == 0 {
		tot = u.PromptTokens + u.CompletionTokens
	}
	return Usage{
		InputTokens:          u.PromptTokens,
		OutputTokens:         u.CompletionTokens,
		NonCachedInputTokens: nonCached,
		CacheReadTokens:      cached,
		CacheWriteTokens:     cacheWrite,
		ReasoningTokens:      reasoning,
		TotalTokens:          tot,
		Cost:                 u.Cost,
	}, true
}

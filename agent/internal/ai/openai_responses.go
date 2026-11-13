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

	"github.com/klauspost/compress/zstd"
)

// streamOpenAIResponses ports OpenCode's open-responses protocol
// (packages/ai/src/protocols/open-responses.ts) for GPT-5 / Codex / OpenAI Responses gateways.
func streamOpenAIResponses(ctx context.Context, req LLMRequest, proxyEnv func() map[string]string, onDelta func(LLMDelta)) (LLMResponse, error) {
	endpoint := resolveEndpoint(req.Provider.BaseURL, "https://api.openai.com/v1", "/responses")
	subscription := req.Provider.AuthMode == ChatGPTAuthMode

	var inputItems []map[string]any

	for _, msg := range req.Messages {
		switch msg.Role {
		case "user":
			var content []map[string]any
			for _, p := range msg.Parts {
				if p.DataURL != "" {
					if p.Type == "image" {
						content = append(content, map[string]any{"type": "input_image", "image_url": p.DataURL})
					} else {
						content = append(content, map[string]any{"type": "input_file", "filename": p.Filename, "file_data": p.DataURL})
					}
				}
				if p.Type == "text" && p.Text != "" {
					content = append(content, map[string]any{
						"type": "input_text",
						"text": p.Text,
					})
				}
			}
			if len(content) > 0 {
				inputItems = append(inputItems, map[string]any{
					"role":    "user",
					"content": content,
				})
			}

		case "assistant":
			for _, p := range msg.Parts {
				switch p.Type {
				case "reasoning":
					if p.Signature != "" {
						ri := map[string]any{
							"type":              "reasoning",
							"encrypted_content": p.Signature,
							"summary":           []map[string]any{},
						}
						if p.Text != "" {
							ri["summary"] = []map[string]any{
								{"type": "summary_text", "text": p.Text},
							}
						}
						if itemID, ok := p.ProviderMeta["itemId"].(string); ok && strings.Contains(itemID, "_") {
							ri["id"] = itemID
						}
						inputItems = append(inputItems, ri)
					}
				case "text":
					if p.Text != "" {
						mi := map[string]any{
							"type": "message",
							"role": "assistant",
							"content": []map[string]any{
								{"type": "output_text", "text": p.Text},
							},
						}
						if itemID, ok := p.ProviderMeta["itemId"].(string); ok && strings.Contains(itemID, "_") {
							mi["id"] = itemID
						}
						inputItems = append(inputItems, mi)
					}
				case "tool-call":
					argsStr := string(p.Input)
					if strings.TrimSpace(argsStr) == "" {
						argsStr = "{}"
					}
					fc := map[string]any{
						"type":      "function_call",
						"call_id":   p.ToolCallID,
						"name":      p.ToolName,
						"arguments": argsStr,
					}
					if itemID, ok := p.ProviderMeta["itemId"].(string); ok && strings.Contains(itemID, "_") {
						fc["id"] = itemID
					}
					inputItems = append(inputItems, fc)
				case "tool-result":
					inputItems = append(inputItems, map[string]any{
						"type":    "function_call_output",
						"call_id": p.ToolCallID,
						"output":  p.Output,
					})
				}
			}

		case "tool":
			for _, p := range msg.Parts {
				if p.Type == "tool-result" {
					inputItems = append(inputItems, map[string]any{
						"type":    "function_call_output",
						"call_id": p.ToolCallID,
						"output":  p.Output,
					})
				}
			}
		}
	}

	body := map[string]any{
		"model":   req.Provider.Model,
		"input":   inputItems,
		"stream":  true,
		"store":   false,
		"include": []string{"reasoning.encrypted_content"},
	}
	if len(req.System) > 0 {
		body["instructions"] = strings.Join(req.System, "\n\n")
	}

	if len(req.Tools) > 0 {
		toolsPayload := make([]map[string]any, 0, len(req.Tools))
		for _, t := range req.Tools {
			toolsPayload = append(toolsPayload, map[string]any{
				"type":        "function",
				"name":        t.Name,
				"description": t.Description,
				"parameters":  t.Parameters,
				"strict":      false,
			})
		}
		body["tools"] = toolsPayload
	}

	maxTok := req.MaxTokens
	if maxTok <= 0 {
		maxTok = req.Provider.MaxOutputTokens
	}
	if maxTok > 0 && !subscription {
		body["max_output_tokens"] = maxTok
	}
	if req.Provider.ReasoningEffort != "" {
		body["reasoning"] = map[string]any{
			"effort":  req.Provider.ReasoningEffort,
			"summary": "auto",
		}
	} else if req.Temperature != nil && !subscription {
		body["temperature"] = *req.Temperature
	}

	rawBody, err := json.Marshal(body)
	if err != nil {
		return LLMResponse{}, err
	}
	compressed := subscription && len(rawBody) > 512*1024
	if compressed {
		encoder, zerr := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedFastest), zstd.WithEncoderConcurrency(1))
		if zerr != nil {
			return LLMResponse{}, errors.New("无法压缩 ChatGPT 附件请求")
		}
		rawBody = encoder.EncodeAll(rawBody, nil)
		encoder.Close()
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(rawBody))
	if err != nil {
		return LLMResponse{}, err
	}
	applyOpenCodeHeaders(httpReq.Header, req)
	if compressed {
		httpReq.Header.Set("Content-Encoding", "zstd")
	}
	if subscription {
		applySubscriptionHeaders(httpReq.Header, req)
	}

	client := newHTTPClient(req.Provider.UseProxy, proxyEnv)
	if subscription {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	defer client.CloseIdleConnections()
	res, err := client.Do(httpReq)
	if err != nil {
		if subscription {
			return LLMResponse{}, errors.New("ChatGPT 订阅请求失败，请检查服务器网络或代理出口")
		}
		return LLMResponse{}, err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		errBody, _ := io.ReadAll(io.LimitReader(res.Body, 256*1024))
		if subscription {
			return LLMResponse{}, subscriptionHTTPError(res.StatusCode, errBody)
		}
		return LLMResponse{}, &HTTPStatusError{Status: res.StatusCode, Body: string(errBody)}
	}

	type respItem struct {
		index            int
		itemType         string // "message" | "reasoning" | "function_call"
		id               string
		callID           string
		name             string
		text             strings.Builder
		encryptedContent string
		args             strings.Builder
		streamedText     bool
	}

	items := map[int]*respItem{}
	idToIdx := map[string]int{}
	var usage Usage
	finishReason := "stop"
	completed := false

	getOrCreate := func(idx int, itemID string) *respItem {
		if itemID != "" {
			if existingIdx, ok := idToIdx[itemID]; ok {
				return items[existingIdx]
			}
		}
		it, ok := items[idx]
		if !ok {
			it = &respItem{index: idx, id: itemID}
			items[idx] = it
		}
		if itemID != "" {
			if it.id == "" {
				it.id = itemID
			}
			idToIdx[itemID] = it.index
		}
		return it
	}

	err = readSSE(res.Body, func(ev sseEvent) error {
		data := strings.TrimSpace(ev.Data)
		if data == "" || data == "[DONE]" {
			return nil
		}

		var packet struct {
			Type        string `json:"type"`
			OutputIndex int    `json:"output_index"`
			ItemID      string `json:"item_id"`
			Delta       string `json:"delta"`
			Text        string `json:"text"`
			Arguments   string `json:"arguments"`
			Item        *struct {
				ID               string `json:"id"`
				Type             string `json:"type"`
				CallID           string `json:"call_id"`
				Name             string `json:"name"`
				Arguments        string `json:"arguments"`
				EncryptedContent string `json:"encrypted_content"`
				Content          []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
				Summary []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"summary"`
			} `json:"item"`
			Response *struct {
				Status            string `json:"status"`
				IncompleteDetails *struct {
					Reason string `json:"reason"`
				} `json:"incomplete_details"`
				Error *struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
				Usage *struct {
					InputTokens        int `json:"input_tokens"`
					OutputTokens       int `json:"output_tokens"`
					TotalTokens        int `json:"total_tokens"`
					InputTokensDetails *struct {
						CachedTokens     int `json:"cached_tokens"`
						CacheWriteTokens int `json:"cache_write_tokens"`
					} `json:"input_tokens_details"`
					OutputTokensDetails *struct {
						ReasoningTokens int `json:"reasoning_tokens"`
					} `json:"output_tokens_details"`
				} `json:"usage"`
			} `json:"response"`
			Error *struct {
				Code    string `json:"code"`
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
		case "error", "response.failed":
			if subscription {
				if packet.Error != nil && packet.Error.Code == "context_length_exceeded" || packet.Response != nil && packet.Response.Error != nil && packet.Response.Error.Code == "context_length_exceeded" {
					return subscriptionContextError()
				}
				return errors.New("ChatGPT 返回流式错误，请检查订阅额度和模型权限后重试")
			}
			return &HTTPStatusError{Status: 500, Body: data}

		case "response.output_item.added", "response.output_item.done":
			if packet.Item == nil {
				return nil
			}
			it := getOrCreate(packet.OutputIndex, packet.Item.ID)
			if packet.Item.Type != "" {
				it.itemType = packet.Item.Type
			}
			if packet.Item.CallID != "" {
				it.callID = packet.Item.CallID
			}
			if packet.Item.Name != "" {
				it.name = packet.Item.Name
			}
			if packet.Item.EncryptedContent != "" {
				it.encryptedContent = packet.Item.EncryptedContent
			}
			if evType == "response.output_item.added" && it.itemType == "function_call" && onDelta != nil {
				cid := it.callID
				if cid == "" {
					cid = it.id
				}
				onDelta(LLMDelta{
					Type:       "tool-call-start",
					ToolCallID: cid,
					ToolName:   it.name,
				})
			}
			if evType == "response.output_item.done" {
				if it.itemType == "function_call" && it.args.Len() == 0 && packet.Item.Arguments != "" {
					it.args.WriteString(packet.Item.Arguments)
				}
				if it.itemType == "message" && !it.streamedText {
					for _, c := range packet.Item.Content {
						if c.Text != "" {
							it.text.WriteString(c.Text)
							it.streamedText = true
							if onDelta != nil {
								onDelta(LLMDelta{Type: "text", Text: c.Text})
							}
						}
					}
				}
				if it.itemType == "reasoning" && !it.streamedText {
					for _, s := range packet.Item.Summary {
						if s.Text != "" {
							it.text.WriteString(s.Text)
							it.streamedText = true
							if onDelta != nil {
								onDelta(LLMDelta{Type: "reasoning", Text: s.Text})
							}
						}
					}
				}
			}

		case "response.output_text.delta":
			it := getOrCreate(packet.OutputIndex, packet.ItemID)
			if it.itemType == "" {
				it.itemType = "message"
			}
			if packet.Delta != "" {
				it.text.WriteString(packet.Delta)
				it.streamedText = true
				if onDelta != nil {
					onDelta(LLMDelta{Type: "text", Text: packet.Delta})
				}
			}

		case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
			it := getOrCreate(packet.OutputIndex, packet.ItemID)
			if it.itemType == "" {
				it.itemType = "reasoning"
			}
			if packet.Delta != "" {
				it.text.WriteString(packet.Delta)
				it.streamedText = true
				if onDelta != nil {
					onDelta(LLMDelta{Type: "reasoning", Text: packet.Delta})
				}
			}

		case "response.function_call_arguments.delta":
			it := getOrCreate(packet.OutputIndex, packet.ItemID)
			if it.itemType == "" {
				it.itemType = "function_call"
			}
			if packet.Delta != "" {
				it.args.WriteString(packet.Delta)
			}

		case "response.function_call_arguments.done":
			it := getOrCreate(packet.OutputIndex, packet.ItemID)
			if it.args.Len() == 0 && packet.Arguments != "" {
				it.args.WriteString(packet.Arguments)
			}

		case "response.completed", "response.incomplete":
			completed = true
			if packet.Response != nil {
				if packet.Response.Usage != nil {
					ru := packet.Response.Usage
					cached, cw, reas := 0, 0, 0
					if ru.InputTokensDetails != nil {
						cached = ru.InputTokensDetails.CachedTokens
						cw = ru.InputTokensDetails.CacheWriteTokens
					}
					if ru.OutputTokensDetails != nil {
						reas = ru.OutputTokensDetails.ReasoningTokens
					}
					nonCached := ru.InputTokens - cached - cw
					if nonCached < 0 {
						nonCached = 0
					}
					tot := ru.TotalTokens
					if tot == 0 {
						tot = ru.InputTokens + ru.OutputTokens
					}
					usage = Usage{
						InputTokens:          ru.InputTokens,
						OutputTokens:         ru.OutputTokens,
						NonCachedInputTokens: nonCached,
						CacheReadTokens:      cached,
						CacheWriteTokens:     cw,
						ReasoningTokens:      reas,
						TotalTokens:          tot,
					}
				}
				if packet.Response.IncompleteDetails != nil {
					switch packet.Response.IncompleteDetails.Reason {
					case "max_output_tokens":
						finishReason = "length"
					case "content_filter":
						finishReason = "content-filter"
					}
				}
			}
			return errSSEStreamDone
		}
		return nil
	})
	if err != nil && !errors.Is(err, errSSEStreamDone) {
		return LLMResponse{}, err
	}
	if subscription && !completed {
		return LLMResponse{}, errors.New("ChatGPT 响应流提前断开，请重新发送；登录到期时请先刷新登录")
	}

	var idxs []int
	for k := range items {
		idxs = append(idxs, k)
	}
	sort.Ints(idxs)

	var parts []Part
	hasToolCalls := false
	for _, idx := range idxs {
		it := items[idx]
		var meta map[string]any
		if it.id != "" {
			meta = map[string]any{"itemId": it.id}
		}
		switch it.itemType {
		case "reasoning":
			if it.text.Len() > 0 || it.encryptedContent != "" {
				parts = append(parts, Part{
					Type:         "reasoning",
					ID:           NewID("prt"),
					Text:         it.text.String(),
					Signature:    it.encryptedContent,
					ProviderMeta: meta,
				})
			}
		case "message":
			if it.text.Len() > 0 {
				parts = append(parts, Part{
					Type:         "text",
					ID:           NewID("prt"),
					Text:         it.text.String(),
					ProviderMeta: meta,
				})
			}
		case "function_call":
			rawArgs := strings.TrimSpace(it.args.String())
			if rawArgs == "" || !json.Valid([]byte(rawArgs)) {
				rawArgs = "{}"
			}
			cid := it.callID
			if cid == "" {
				cid = it.id
			}
			if cid == "" {
				cid = NewID("call")
			}
			parts = append(parts, Part{
				Type:         "tool-call",
				ID:           NewID("prt"),
				ToolCallID:   cid,
				ToolName:     it.name,
				Input:        json.RawMessage(rawArgs),
				ProviderMeta: meta,
			})
			hasToolCalls = true
			if onDelta != nil {
				onDelta(LLMDelta{
					Type:       "tool-call-end",
					ToolCallID: cid,
					ToolName:   it.name,
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

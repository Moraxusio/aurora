//go:build linux || windows

package ai

import (
	"context"
	"errors"
	"math"
	"sync"
	"time"
)

type runMeter struct {
	mu                                     sync.Mutex
	config                                 ExtensionConfig
	deadline                               time.Time
	steps, tokens, heldTokens, outputBytes int
	cost, heldCost                         float64
}

func newRunMeter(config ExtensionConfig) *runMeter {
	return &runMeter{config: config, deadline: time.Now().Add(time.Duration(config.Budget.Seconds) * time.Second)}
}
func (m *runMeter) reserve(req *LLMRequest) (func(*LLMResponse, bool), error) {
	input := EstimateMessagesTokens(req.Messages) + contextOverhead(req.System, req.Tools)
	output := req.MaxTokens
	if output <= 0 {
		output = req.Provider.MaxOutputTokens
	}
	if output <= 0 {
		output = 8192
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	b := m.config.Budget
	price, priced := m.config.Prices[req.Provider.Model]
	if b.Cost > 0 && !priced {
		return nil, errors.New("成本预算需要为当前模型配置每百万 token 的价格")
	}
	if (!req.BudgetAuxiliary && m.steps >= b.Steps) || time.Now().After(m.deadline) {
		return nil, errors.New("AI 已达到本次运行的步骤或时间预算")
	}
	if m.outputBytes >= b.OutputBytes {
		return nil, errors.New("AI 已达到本次运行的输出预算")
	}
	output = min(output, b.Tokens-m.tokens-m.heldTokens-input)
	inputCost := float64(input) * max(price.Input, price.CacheRead, price.CacheWrite) / 1e6
	if b.Cost > 0 {
		remaining := b.Cost - m.cost - m.heldCost - inputCost
		if remaining <= 0 {
			return nil, errors.New("AI 已达到本次运行的成本预算")
		}
		if price.Output > 0 {
			output = min(output, int(math.Floor(remaining*1e6/price.Output)))
		}
	}
	if output < 1 {
		return nil, errors.New("AI 已达到本次运行的 token 预算")
	}
	reservedTokens := input + output
	reservedCost := inputCost + float64(output)*price.Output/1e6
	if !req.BudgetAuxiliary {
		m.steps++
	}
	m.heldTokens += reservedTokens
	m.heldCost += reservedCost
	req.MaxTokens = output
	return func(resp *LLMResponse, failed bool) {
		u := &resp.Usage
		if u.TotalTokens == 0 && u.InputTokens+u.OutputTokens > 0 {
			u.TotalTokens = u.InputTokens + u.OutputTokens
		}
		if u.TotalTokens == 0 {
			u.InputTokens = input
			u.OutputTokens = EstimateMessagesTokens([]Message{{Parts: resp.Parts}})
			if failed {
				u.OutputTokens = output
			}
			u.NonCachedInputTokens = input
			u.TotalTokens = u.InputTokens + u.OutputTokens
			u.Estimated = true
		}
		if priced {
			nonCached := max(0, u.InputTokens-u.CacheReadTokens-u.CacheWriteTokens)
			u.Cost = (float64(nonCached)*price.Input + float64(u.OutputTokens)*price.Output +
				float64(u.CacheReadTokens)*price.CacheRead + float64(u.CacheWriteTokens)*price.CacheWrite) / 1e6
		}
		m.mu.Lock()
		defer m.mu.Unlock()
		m.heldTokens -= reservedTokens
		m.heldCost -= reservedCost
		m.tokens += u.TotalTokens
		m.cost += u.Cost
	}, nil
}
func streamBudgeted(ctx context.Context, req LLMRequest, proxy func() map[string]string, onDelta func(LLMDelta), meter *runMeter) (LLMResponse, error) {
	if meter == nil {
		return StreamLLM(ctx, req, proxy, onDelta)
	}
	finish, err := meter.reserve(&req)
	if err != nil {
		return LLMResponse{}, err
	}
	ctx, cancel := context.WithDeadline(ctx, meter.deadline)
	defer cancel()
	exceeded := false
	response, err := StreamLLM(ctx, req, proxy, func(d LLMDelta) {
		meter.mu.Lock()
		meter.outputBytes += len(d.Text) + len(d.ToolInput)
		over := meter.outputBytes > meter.config.Budget.OutputBytes
		meter.mu.Unlock()
		if over {
			exceeded = true
			cancel()
			return
		}
		if onDelta != nil {
			onDelta(d)
		}
	})
	finish(&response, err != nil)
	if exceeded {
		return response, errors.New("AI 输出超过本次运行的字节预算")
	}
	return response, err
}

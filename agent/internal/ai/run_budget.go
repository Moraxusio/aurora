//go:build linux || windows

package ai

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"
)

// RunBudgetState is a credential-free receipt for one admitted run. All model
// requests (including children, titles and compaction) share this meter.
type RunBudgetState struct {
	ID              string          `json:"id"`
	Source          string          `json:"source"`
	Limits          RunBudget       `json:"limits"`
	Enabled         bool            `json:"enabled"`
	AutoCompact     bool            `json:"auto_compact"`
	Snapshots       bool            `json:"snapshots"`
	Subagents       SubagentOptions `json:"subagents"`
	ChildrenActive  int             `json:"children_active"`
	ChildrenStarted int             `json:"children_started"`
	StartedAt       int64           `json:"started_at"`
	Elapsed         float64         `json:"elapsed_seconds"`
	Steps           int             `json:"steps"`
	Auxiliary       int             `json:"auxiliary"`
	Tokens          int             `json:"tokens"`
	Reserved        int             `json:"reserved_tokens"`
	OutputBytes     int             `json:"output_bytes"`
	Cost            float64         `json:"cost"`
	ReservedCost    float64         `json:"reserved_cost"`
	Estimated       bool            `json:"estimated"`
	Unpriced        bool            `json:"unpriced"`
	BlockedBy       string          `json:"blocked_by,omitempty"`
	NextInput       int             `json:"next_input_tokens,omitempty"`
}

type budgetError struct {
	kind string
	text string
}

func (e *budgetError) Error() string { return e.text }

type runMeter struct {
	mu                                                sync.Mutex
	config                                            ExtensionConfig
	limits                                            RunBudget
	childSlots                                        chan struct{}
	spawnApproval                                     sync.Mutex
	childrenActive, childrenStarted                   int
	id, source                                        string
	started, deadline                                 time.Time
	steps, auxiliary, tokens, heldTokens, outputBytes int
	cost, heldCost                                    float64
	estimated, unpriced                               bool
	blockedBy                                         string
	nextInput                                         int
	onChange                                          func()
}

func newRunMeter(config ExtensionConfig) *runMeter {
	now := time.Now()
	limits := config.Budget
	if !enabledByDefault(config.BudgetEnabled) {
		limits = RunBudget{}
	}
	m := &runMeter{config: config, limits: limits, childSlots: make(chan struct{}, config.Subagents.resolved().MaxParallel), id: NewID("run"), source: "default", started: now}
	if limits.Seconds > 0 {
		m.deadline = now.Add(time.Duration(limits.Seconds) * time.Second)
	}
	return m
}

func (m *runMeter) snapshot() *RunBudgetState {
	if m == nil {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return &RunBudgetState{
		ID: m.id, Source: m.source, Limits: m.limits, Enabled: enabledByDefault(m.config.BudgetEnabled),
		AutoCompact: enabledByDefault(m.config.AutoCompact), Snapshots: enabledByDefault(m.config.Snapshots),
		Subagents: m.config.Subagents.resolved(), ChildrenActive: m.childrenActive, ChildrenStarted: m.childrenStarted,
		StartedAt: m.started.UnixMilli(), Elapsed: time.Since(m.started).Seconds(),
		Steps: m.steps, Auxiliary: m.auxiliary, Tokens: m.tokens, Reserved: m.heldTokens,
		OutputBytes: m.outputBytes, Cost: m.cost, ReservedCost: m.heldCost,
		Estimated: m.estimated, Unpriced: m.unpriced, BlockedBy: m.blockedBy, NextInput: m.nextInput,
	}
}

func (m *runMeter) publish() {
	if m != nil && m.onChange != nil {
		m.onChange()
	}
}

func (m *runMeter) context(ctx context.Context) (context.Context, context.CancelFunc) {
	if m != nil && !m.deadline.IsZero() {
		return context.WithDeadline(ctx, m.deadline)
	}
	return context.WithCancel(ctx)
}

// Called with mu held. The explanation includes both settled usage and the
// next request's admission requirement; "remaining" need not be zero.
func (m *runMeter) blocked(kind string, text string) error {
	m.blockedBy = kind
	return &budgetError{kind, text}
}

func (m *runMeter) timeError() error {
	if m == nil || m.deadline.IsZero() || time.Now().Before(m.deadline) {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.blocked("seconds", fmt.Sprintf("本次运行已达到时间预算：%.0f / %d 秒。可调整项目预算后继续。", time.Since(m.started).Seconds(), m.config.Budget.Seconds))
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
	b := m.limits
	m.nextInput = input
	price, priced := m.config.Prices[req.Provider.Model]
	if b.Cost > 0 && !priced {
		return nil, m.blocked("pricing", fmt.Sprintf("已设置金额预算，但模型 %s 尚未配置价格。请在项目的「模型价格」中填写单价，或取消金额限制。", req.Provider.Model))
	}
	if !m.deadline.IsZero() && time.Now().After(m.deadline) {
		return nil, m.blocked("seconds", fmt.Sprintf("本次运行已达到时间预算：%.0f / %d 秒。", time.Since(m.started).Seconds(), b.Seconds))
	}
	if !req.BudgetAuxiliary && b.Steps > 0 && m.steps >= b.Steps {
		return nil, m.blocked("steps", fmt.Sprintf("本次运行已达到模型步骤预算：%d / %d 步（含子任务）。", m.steps, b.Steps))
	}
	if b.OutputBytes > 0 && m.outputBytes >= b.OutputBytes {
		return nil, m.blocked("outputBytes", fmt.Sprintf("本次运行已达到输出预算：%d / %d 字节。", m.outputBytes, b.OutputBytes))
	}
	if b.Tokens > 0 {
		output = min(output, b.Tokens-m.tokens-m.heldTokens-input)
		if output < 1 {
			return nil, m.blocked("tokens", fmt.Sprintf("本次运行的 token 预算不足：已用 %d，其他请求预留 %d，上限 %d；下一步输入预计 %d tokens，另需输出空间。累计包括每次重发的上下文、子任务、标题和摘要。可提高预算、取消该限制，或压缩上下文后继续。", m.tokens, m.heldTokens, b.Tokens, input))
		}
	}
	inputCost := float64(input) * max(price.Input, price.CacheRead, price.CacheWrite) / 1e6
	if b.Cost > 0 {
		remaining := b.Cost - m.cost - m.heldCost - inputCost
		if remaining <= 0 {
			return nil, m.blocked("cost", fmt.Sprintf("本次运行的金额预算不足：已用 $%.6f，预留 $%.6f，上限 $%.6f；下一步输入预计 $%.6f。", m.cost, m.heldCost, b.Cost, inputCost))
		}
		if price.Output > 0 {
			output = min(output, int(math.Min(float64(output), math.Floor(remaining*1e6/price.Output))))
		}
		if output < 1 {
			return nil, m.blocked("cost", "本次运行剩余金额不足以预留一个输出 token。请调整项目金额预算。")
		}
	}
	reservedTokens := input + output
	m.blockedBy = ""
	reservedCost := inputCost + float64(output)*price.Output/1e6
	if req.BudgetAuxiliary {
		m.auxiliary++
	} else {
		m.steps++
	}
	m.heldTokens += reservedTokens
	m.heldCost += reservedCost
	req.MaxTokens = output
	var once sync.Once
	return func(resp *LLMResponse, failed bool) {
		once.Do(func() {
			u := &resp.Usage
			if u.TotalTokens == 0 && u.InputTokens+u.OutputTokens > 0 {
				u.TotalTokens = u.InputTokens + u.OutputTokens
			}
			if u.TotalTokens == 0 {
				// A failed admission/HTTP error with no response is not evidence
				// that all requested output was generated. Estimate observed
				// partial responses only; never bill the reservation as usage.
				u.Estimated = true
				if !failed || len(resp.Parts) > 0 {
					u.InputTokens = input
					u.OutputTokens = EstimateMessagesTokens([]Message{{Parts: resp.Parts}})
					u.NonCachedInputTokens = input
					u.TotalTokens = u.InputTokens + u.OutputTokens
				}
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
			m.estimated = m.estimated || u.Estimated
			m.unpriced = m.unpriced || !priced
		})
	}, nil
}

func streamBudgeted(ctx context.Context, req LLMRequest, proxy func() map[string]string, onDelta func(LLMDelta), meter *runMeter) (LLMResponse, error) {
	if meter == nil {
		return StreamLLM(ctx, req, proxy, onDelta)
	}
	defer meter.publish()
	finish, err := meter.reserve(&req)
	if err != nil {
		return LLMResponse{}, err
	}
	meter.publish()
	ctx, cancel := meter.context(ctx)
	defer cancel()
	exceeded := false
	response, err := StreamLLM(ctx, req, proxy, func(d LLMDelta) {
		meter.mu.Lock()
		meter.outputBytes += len(d.Text) + len(d.ToolInput)
		over := meter.limits.OutputBytes > 0 && meter.outputBytes > meter.limits.OutputBytes
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
		meter.mu.Lock()
		defer meter.mu.Unlock()
		return response, meter.blocked("outputBytes", fmt.Sprintf("本次运行输出超过预算：%d / %d 字节。", meter.outputBytes, meter.config.Budget.OutputBytes))
	}
	if deadlineErr := meter.timeError(); deadlineErr != nil {
		return response, deadlineErr
	}
	return response, err
}

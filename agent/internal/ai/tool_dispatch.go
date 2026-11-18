//go:build linux || windows

package ai

import (
	"context"
	"fmt"
	"strings"
)

type toolSignature struct{ name, args string }

// Only adjacent independent delegations run concurrently. Every other tool is
// a barrier, preserving the model's file/shell ordering and step snapshots.
// Completion checkpoints are serialized; a failed write cancels and joins all
// in-flight children before the extension runtime or session can be closed.
func (e *Env) executeStepTools(ctx context.Context, tc toolContext, calls []Part, progress Message, recent *[]toolSignature) ([]Part, error) {
	policy := tc.extensions.config.Tools.resolved()
	parallel := tc.extensions.config.Subagents.resolved().MaxParallel
	declared := map[string]bool{}
	for _, def := range append(configuredToolDefinitions(tc.session.Agent, tc.depth, tc.provider, tc.extensions),
		tc.extensions.definitions(tc.session.Agent, tc.provider)...) {
		declared[def.Name] = true
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		index int
		part  Part
	}
	results := make([]Part, len(calls))
	original := append([]Part(nil), progress.Parts...)
	var persistErr error
	collect := func(r result) {
		results[r.index] = r.part
		progress.Parts = append([]Part(nil), original...)
		for _, p := range results {
			if p.ID != "" {
				progress.Parts = append(progress.Parts, p)
			}
		}
		if persistErr == nil {
			persistErr = e.checkpointStep(progress)
			if persistErr != nil {
				cancel()
			}
		}
		call := calls[r.index]
		e.broadcast(StreamEvent{Type: "tool.done", SessionID: tc.session.ID, MessageID: tc.messageID,
			ToolCallID: call.ToolCallID, ToolName: call.ToolName, Input: call.Input,
			Output: r.part.Output, IsError: r.part.IsError, Metadata: r.part.Metadata})
	}
	prepare := func(index int) bool {
		if index >= policy.MaxCallsPerStep || policy.RepeatLimit == 0 {
			return false
		}
		call := calls[index]
		sig := toolSignature{call.ToolName, strings.TrimSpace(string(call.Input))}
		*recent = append(*recent, sig)
		if len(*recent) > policy.RepeatLimit {
			*recent = (*recent)[len(*recent)-policy.RepeatLimit:]
		}
		if len(*recent) < policy.RepeatLimit {
			return false
		}
		for _, previous := range *recent {
			if previous != sig {
				return false
			}
		}
		*recent = nil
		return true
	}
	exec := func(index int, repeated bool) result {
		call := calls[index]
		local := tc
		local.callID = call.ToolCallID
		var out ToolExecResult
		switch {
		case ctx.Err() != nil:
			out = ToolExecResult{Output: "Not executed: run cancelled.", IsError: true, Metadata: map[string]any{"cancelled": true}}
		case index >= policy.MaxCallsPerStep:
			out = ToolExecResult{Output: fmt.Sprintf("Not executed: project policy allows %d tool calls per step.", policy.MaxCallsPerStep), IsError: true}
		default:
			e.broadcast(StreamEvent{Type: "tool.running", SessionID: tc.session.ID, MessageID: tc.messageID,
				ToolCallID: call.ToolCallID, ToolName: call.ToolName, Input: call.Input,
				Metadata: toolRuntimeMetadata(call.ToolName, tc.provider, e.proxyFor(tc.provider))})
			var approvalErr error
			if repeated && declared[call.ToolName] {
				// Parent approvals share a gate so concurrent spawn requests do
				// not replace one another in clients with one approval surface.
				e.mu.Lock()
				run := e.running[tc.session.ID]
				e.mu.Unlock()
				if run != nil {
					run.meter.spawnApproval.Lock()
				}
				q := PermissionQuestion{ID: NewID("perm"), SessionID: tc.session.ID, MessageID: tc.messageID,
					CallID: call.ToolCallID, Tool: call.ToolName, Action: "doom_loop",
					Resource: call.ToolName + " " + truncateShort(string(call.Input), 120),
					Reason:   fmt.Sprintf("相同工具和参数连续出现 %d 次，是否继续？", policy.RepeatLimit)}
				approvalErr = e.perms.Ask(ctx, q, func(pq PermissionQuestion) {
					e.broadcast(StreamEvent{Type: "permission.ask", SessionID: tc.session.ID,
						MessageID: tc.messageID, ToolCallID: call.ToolCallID, Permission: &pq})
				})
				if run != nil {
					run.meter.spawnApproval.Unlock()
				}
			}
			if approvalErr != nil {
				out = ToolExecResult{Output: approvalErr.Error(), IsError: true}
			} else {
				out = executeTool(ctx, local, call.ToolName, call.Input)
			}
		}
		return result{index, Part{Type: "tool-result", ID: NewID("prt"), ToolName: call.ToolName,
			ToolCallID: call.ToolCallID, Output: out.Output, IsError: out.IsError, Metadata: out.Metadata, Attachments: out.Attachments}}
	}
	for start := 0; start < len(calls); {
		end := start + 1
		if calls[start].ToolName == "subagent" && parallel > 1 {
			for end < len(calls) && calls[end].ToolName == "subagent" && end-start < parallel {
				end++
			}
		}
		if end-start == 1 {
			collect(exec(start, prepare(start)))
		} else {
			done := make(chan result, end-start)
			for i := start; i < end; i++ {
				repeated := prepare(i)
				go func(index int, repeat bool) { done <- exec(index, repeat) }(i, repeated)
			}
			for i := start; i < end; i++ {
				collect(<-done)
			}
		}
		if persistErr != nil {
			return results, persistErr
		}
		start = end
	}
	return results, nil
}

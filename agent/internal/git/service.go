//go:build linux || windows

package git

import "aurora3/internal/service"

// Service is the "git" service (D-45). Operation names are v2's
// (internal/agent/ops.go).
func (e *Env) Service() service.Service { return svc{e} }

type svc struct{ e *Env }

func (svc) ID() string { return "git" }

func (svc) Dependencies() []service.Dependency {
	return []service.Dependency{{Name: "git", Purpose: "git 操作需要服务器上的 git", Required: true}}
}

func (v svc) Operations() []service.Operation {
	e := v.e
	u := func(name string, h service.Handler) service.Operation {
		return service.Operation{Name: name, Handle: h}
	}
	return []service.Operation{
		u("git.repos", e.gitRepos),
		u("git.status", e.gitStatus),
		u("git.show", e.gitShow),
		u("git.stage", e.gitStage),
		u("git.unstage", e.gitUnstage),
		u("git.discard", e.gitDiscard),
		u("git.commit", e.gitCommit),
		u("git.branches", e.gitBranches),
		u("git.checkout", e.gitCheckout),
		u("git.log", e.gitLog),
		u("git.commitFiles", e.gitCommitFiles),
		u("git.blame", e.gitBlame),
		{Name: "git.sync", Stream: e.gitSync},
		u("git.stageContent", e.gitStageContent),
		u("git.stash", e.gitStash),
		u("git.op", e.gitOp),
		u("git.branch", e.gitBranch),
		u("git.tag", e.gitTag),
		u("git.init", e.gitInit),
		u("git.numstat", e.gitNumstat),
		u("git.ignore", e.gitIgnore),
		u("git.remote", e.gitRemote),
		u("git.diff", e.gitDiff),
		u("git.apply", e.gitApply),
	}
}

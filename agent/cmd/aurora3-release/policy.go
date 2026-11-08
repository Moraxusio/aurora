package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"aurora3/internal/update"
)

func policyCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("policy", flag.ContinueOnError)
	key := fs.String("key", "", "release private key")
	input := fs.String("input", "", "policy JSON with revoked and min_ok (optional)")
	dir := fs.String("out", "", "agent directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" {
		return fmt.Errorf("--out is required")
	}
	p := update.Policy{Product: update.ProductAgent, Channel: update.ChannelStable, Created: time.Now().UTC().Format(time.RFC3339), Revoked: []string{}}
	if *input != "" {
		b, err := os.ReadFile(*input)
		if err != nil {
			return err
		}
		if err = json.Unmarshal(b, &p); err != nil {
			return err
		}
		p.Product = update.ProductAgent
		p.Channel = update.ChannelStable
		p.Created = time.Now().UTC().Format(time.RFC3339)
	}
	k, err := readKey(*key)
	if err != nil {
		return err
	}
	b, s, err := update.SignPolicy(p, k)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(*dir, 0o755); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(*dir, "policy.json"), b, 0o644); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(*dir, "policy.sig"), update.SignatureText(s), 0o644); err != nil {
		return err
	}
	_, err = fmt.Fprintln(out, "signed upgrade policy", p.Product, p.MinOK)
	return err
}

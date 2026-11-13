package files

import (
	"aurora3/internal/wire"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"time"
)

// Bounded directory snapshots also detect replace-on-save and work without an
// elevated account. Only explicitly subscribed folders are scanned, never trees.
func (e *Env) fsWatch(ctx context.Context, st net.Conn, raw json.RawMessage) error {
	if err := wire.WriteJSON(st, wire.Response{OK: true}); err != nil {
		return err
	}
	type item struct {
		Root string `json:"root"`
		Path string `json:"path"`
	}
	updates := make(chan []item, 1)
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		defer cancel()
		for {
			var ctl struct {
				Type  string `json:"type"`
				Items []item `json:"items"`
			}
			if wire.ReadJSON(st, &ctl) != nil {
				return
			}
			if ctl.Type == "set" {
				if len(ctl.Items) > 512 {
					ctl.Items = ctl.Items[:512]
				}
				select {
				case updates <- ctl.Items:
				case <-cctx.Done():
					return
				}
			}
		}
	}()
	items := []item{}
	previous := map[item]string{}
	tick := time.NewTicker(800 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-cctx.Done():
			return nil
		case items = <-updates:
			previous = map[item]string{}
		case <-tick.C:
			for _, it := range items {
				root, err := e.openRoot(it.Root)
				if err != nil {
					continue
				}
				rel, err := cleanRel(it.Path)
				if err != nil {
					root.Close()
					continue
				}
				d, err := root.Open(rel)
				signature := "missing"
				if err == nil {
					entries, err := d.ReadDir(maxListEntries + 1)
					d.Close()
					if err == nil {
						signature = ""
						for _, ent := range entries {
							fi, err := ent.Info()
							if err == nil {
								signature += fmt.Sprintf("%s:%d:%d;", ent.Name(), fi.Size(), fi.ModTime().UnixNano())
							}
						}
					}
				}
				root.Close()
				if old, ok := previous[it]; !ok || old != signature {
					_ = st.SetWriteDeadline(time.Now().Add(10 * time.Second))
					if err := wire.WriteJSON(st, map[string]any{"type": "change", "root": it.Root, "path": it.Path, "self": true}); err != nil {
						return err
					}
				}
				previous[it] = signature
			}
		}
	}
}

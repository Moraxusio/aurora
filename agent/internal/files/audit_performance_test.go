package files

import (
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"testing"
)

func auditPaths(count int) []string {
	paths := make([]string, count)
	for i := range paths {
		paths[i] = fmt.Sprintf("src/module%03d/sub%02d/file%06d.go", i%173, i%19, i)
	}
	rand.New(rand.NewSource(42)).Shuffle(len(paths), func(i, j int) { paths[i], paths[j] = paths[j], paths[i] })
	return paths
}

func BenchmarkAuditRankFiles(b *testing.B) {
	for _, count := range []int{10000, 100000, 300000} {
		paths := auditPaths(count)
		for _, query := range []string{"", "file"} {
			b.Run(fmt.Sprintf("files_%d/query_%q", count, query), func(b *testing.B) {
				b.ReportAllocs()
				for i := 0; i < b.N; i++ {
					if len(rankFiles(paths, query, 100)) != 100 {
						b.Fatal("unexpected result size")
					}
				}
			})
		}
	}
}

func referenceRankFiles(files []string, q string, limit int) []found {
	var out []found
	for _, f := range files {
		if score := fuzzyScore(f, q); score >= 0 {
			out = append(out, found{Path: f, score: score})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].score != out[j].score {
			return out[i].score > out[j].score
		}
		return out[i].Path < out[j].Path
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func TestRankFilesMatchesFullSort(t *testing.T) {
	paths := append(auditPaths(10000), "README.md", ".bashrc", "src/中文.go", "src/Über.go", "src/a.go", "src/a.go")
	for _, query := range []string{"", "file", "F I L E", "rmd", "中文", "über", "bashrc", "zzzzzz", " "} {
		for _, limit := range []int{1, 7, 100, 500, 20000} {
			got, want := rankFiles(paths, query, limit), referenceRankFiles(paths, query, limit)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("query=%q limit=%d: ranking differs from full stable sort", query, limit)
			}
		}
	}
}

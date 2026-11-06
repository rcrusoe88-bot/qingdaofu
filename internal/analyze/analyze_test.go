//go:build windows

package analyze

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScanAggregatesKnownTree(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "a"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "b", "c"), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(p string, n int) {
		if err := os.WriteFile(p, make([]byte, n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(root, "a", "one.bin"), 1024)
	write(filepath.Join(root, "a", "two.bin"), 2048)
	write(filepath.Join(root, "b", "c", "deep.bin"), 4096)
	write(filepath.Join(root, "top.bin"), 512)

	node, err := Scan(root, 3)
	if err != nil {
		t.Fatal(err)
	}
	if want := int64(1024 + 2048 + 4096 + 512); node.Size != want {
		t.Fatalf("root size = %d, want %d", node.Size, want)
	}
	if node.Files != 4 {
		t.Fatalf("root files = %d, want 4", node.Files)
	}
	if len(node.Largest) == 0 || node.Largest[0].Size != 4096 {
		t.Fatalf("largest file = %+v, want deep.bin 4096", node.Largest)
	}
	var a, b int64
	for _, c := range node.Children {
		switch c.Name {
		case "a":
			a = c.Size
		case "b":
			b = c.Size
		}
	}
	if a != 3072 || b != 4096 {
		t.Fatalf("child sizes a=%d b=%d, want 3072/4096", a, b)
	}
}

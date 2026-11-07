//go:build windows

// Package analyze builds a read-only disk-usage tree for the GUI treemap.
// It walks once, aggregates sizes into directories up to maxDepth, and keeps
// the largest files so the "最大文件" tab does not need a second scan.
package analyze

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/disk"
)

type Node struct {
	Name      string `json:"Name"`
	Path      string `json:"Path"`
	Size      int64  `json:"Size"`
	IsDir     bool   `json:"IsDir"`
	Files     int    `json:"Files"`
	Children  []Node `json:"Children"`
	Largest   []File `json:"Largest,omitempty"`
	Truncated bool   `json:"Truncated,omitempty"`
}

type File struct {
	Name string `json:"Name"`
	Path string `json:"Path"`
	Size int64  `json:"Size"`
}

type Drive struct {
	Name  string `json:"Name"`
	Path  string `json:"Path"`
	Total int64  `json:"Total"`
	Free  int64  `json:"Free"`
}

type agg struct {
	name     string
	path     string
	size     int64
	files    int
	depth    int
	children map[string]*agg
	top      []File
}

// Scan walks root once. A 60s budget keeps a huge drive from freezing the GUI;
// the returned root is marked Truncated when the budget was hit.
func Scan(root string, maxDepth int) (Node, error) {
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			home = "C:\\"
		}
		root = home
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return Node{}, err
	}
	root = filepath.Clean(abs)
	st, err := os.Stat(root)
	if err != nil {
		return Node{}, err
	}
	if !st.IsDir() {
		return Node{}, &os.PathError{Op: "analyze", Path: root, Err: os.ErrInvalid}
	}
	if maxDepth <= 0 || maxDepth > 6 {
		maxDepth = 3
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	name := filepath.Base(root)
	if name == "." || name == string(os.PathSeparator) {
		name = root
	}
	ra := &agg{name: name, path: root, depth: 0, children: map[string]*agg{}}
	dirs := map[string]*agg{root: ra}
	var largest []File
	truncated := false

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if ctx.Err() != nil {
			truncated = true
			return filepath.SkipAll
		}
		if walkErr != nil {
			return nil // unreadable entries are skipped, not fatal
		}
		if path == root {
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			base := d.Name()
			if strings.HasPrefix(base, "$") || strings.EqualFold(base, "System Volume Information") {
				return filepath.SkipDir
			}
			rel, relErr := filepath.Rel(root, path)
			if relErr != nil {
				return nil
			}
			depth := strings.Count(rel, string(os.PathSeparator)) + 1
			if depth > maxDepth {
				return nil
			}
			parent := dirs[filepath.Dir(path)]
			if parent == nil {
				return nil
			}
			a := &agg{name: base, path: path, depth: depth, children: map[string]*agg{}}
			dirs[path] = a
			parent.children[path] = a
			return nil
		}

		info, infoErr := d.Info()
		if infoErr != nil {
			return nil
		}
		size := info.Size()
		if size < 0 {
			size = 0
		}
		// Size and count flow up through every aggregated ancestor.
		for dir := filepath.Dir(path); ; {
			if a := dirs[dir]; a != nil {
				a.size += size
				a.files++
			}
			if dir == root {
				break
			}
			next := filepath.Dir(dir)
			if next == dir {
				break
			}
			dir = next
		}
		if p := dirs[filepath.Dir(path)]; p != nil {
			p.top = append(p.top, File{Name: d.Name(), Path: path, Size: size})
		}
		largest = append(largest, File{Name: d.Name(), Path: path, Size: size})
		if len(largest) > 20000 {
			largest = topFiles(largest, 2000)
		}
		return nil
	})
	if err != nil && err != filepath.SkipAll {
		return Node{}, err
	}

	node := build(ra, 0)
	node.Largest = topFiles(largest, 120)
	node.Truncated = truncated
	return node, nil
}

func build(a *agg, depth int) Node {
	n := Node{Name: a.name, Path: a.path, Size: a.size, IsDir: true, Files: a.files}
	children := make([]Node, 0, len(a.children)+len(a.top))
	for _, c := range a.children {
		children = append(children, build(c, depth+1))
	}
	for _, f := range topFiles(a.top, 60) {
		children = append(children, Node{Name: f.Name, Path: f.Path, Size: f.Size, IsDir: false})
	}
	sort.Slice(children, func(i, j int) bool {
		if children[i].Size == children[j].Size {
			return children[i].Name < children[j].Name
		}
		return children[i].Size > children[j].Size
	})
	if len(children) > 60 {
		rest := int64(0)
		for _, c := range children[60:] {
			rest += c.Size
		}
		children = append(children[:60], Node{Name: "其他", Size: rest, IsDir: false})
	}
	n.Children = children
	return n
}

func topFiles(in []File, n int) []File {
	out := append([]File(nil), in...)
	sort.Slice(out, func(i, j int) bool {
		if out[i].Size == out[j].Size {
			return out[i].Path < out[j].Path
		}
		return out[i].Size > out[j].Size
	})
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// Drives lists fixed/removable drives with total/free bytes for the breadcrumb.
func Drives() []Drive {
	parts, err := disk.Partitions(false)
	if err != nil {
		return nil
	}
	var out []Drive
	seen := map[string]bool{}
	for _, p := range parts {
		dev := strings.ToUpper(p.Device)
		if len(dev) < 2 || dev[1] != ':' || seen[dev] {
			continue
		}
		u, err := disk.Usage(p.Mountpoint)
		if err != nil || u.Total == 0 {
			continue
		}
		seen[dev] = true
		out = append(out, Drive{Name: dev, Path: p.Mountpoint, Total: int64(u.Total), Free: int64(u.Free)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

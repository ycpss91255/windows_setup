//go:build windows

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var setFileInformationByHandle = syscall.NewLazyDLL("kernel32.dll").NewProc("SetFileInformationByHandle")
var getFileInformationByHandleEx = syscall.NewLazyDLL("kernel32.dll").NewProc("GetFileInformationByHandleEx")

const deleteAccess = 0x00010000
const openReparse = 0x00200000

type lockedEntry struct {
	h    syscall.Handle
	path string
	dir  bool
}

type enumeratedEntry struct {
	name string
	id   uint64
}

func rejectNamedStreams(h syscall.Handle) error {
	buf := make([]uint64, 8192)
	ok, _, err := getFileInformationByHandleEx.Call(uintptr(h), 7, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)*8))
	if ok == 0 {
		if err == syscall.Errno(38) {
			return nil
		} // no streams
		return fmt.Errorf("enumerate streams: %w", err)
	}
	data := unsafe.Slice((*byte)(unsafe.Pointer(&buf[0])), len(buf)*8)
	for off := 0; ; {
		if off+24 > len(data) {
			return errors.New("invalid stream record")
		}
		next := *(*uint32)(unsafe.Pointer(&data[off]))
		n := *(*uint32)(unsafe.Pointer(&data[off+4]))
		if n%2 != 0 || int(n) > len(data)-off-24 {
			return errors.New("invalid stream name")
		}
		name := syscall.UTF16ToString(unsafe.Slice((*uint16)(unsafe.Pointer(&data[off+24])), int(n)/2))
		if name != "" && name != "::$DATA" {
			return errors.New("named data stream rejected")
		}
		if next == 0 {
			return nil
		}
		if next%8 != 0 || int(next) > len(data)-off-24 {
			return errors.New("invalid stream offset")
		}
		off += int(next)
	}
}

func enumerateIDs(h syscall.Handle) ([]enumeratedEntry, error) {
	var result []enumeratedEntry
	buf := make([]uint64, 8192) // FILE_ID_BOTH_DIR_INFO requires eight-byte alignment.
	for {
		ok, _, err := getFileInformationByHandleEx.Call(uintptr(h), 10, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)*8))
		if ok == 0 {
			if err == syscall.Errno(18) {
				return result, nil
			}
			return nil, err
		}
		data := unsafe.Slice((*byte)(unsafe.Pointer(&buf[0])), len(buf)*8)
		for offset := 0; ; {
			if offset+104 > len(data) {
				return nil, errors.New("invalid directory record")
			}
			next := *(*uint32)(unsafe.Pointer(&data[offset]))
			n := *(*uint32)(unsafe.Pointer(&data[offset+60]))
			id := *(*uint64)(unsafe.Pointer(&data[offset+96]))
			if n%2 != 0 || int(n) > len(data)-offset-104 {
				return nil, errors.New("invalid directory name")
			}
			name := syscall.UTF16ToString(unsafe.Slice((*uint16)(unsafe.Pointer(&data[offset+104])), int(n)/2))
			if name != "." && name != ".." {
				result = append(result, enumeratedEntry{name, id})
			}
			if next == 0 {
				break
			}
			if next%8 != 0 || int(next) > len(data)-offset-104 {
				return nil, errors.New("invalid directory offset")
			}
			offset += int(next)
		}
	}
}

func openLocked(path string, deletable bool) (lockedEntry, string, error) {
	return openLockedMode(path, deletable, false)
}
func openLockedMode(path string, deletable, writable bool) (lockedEntry, string, error) {
	var x lockedEntry
	p, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		return x, "", e
	}
	access := uint32(syscall.GENERIC_READ)
	share := uint32(syscall.FILE_SHARE_READ | syscall.FILE_SHARE_WRITE)
	if deletable {
		access = deleteAccess | syscall.GENERIC_READ
		share = syscall.FILE_SHARE_READ
	}
	if writable {
		access |= syscall.GENERIC_WRITE
	}
	h, e := syscall.CreateFile(p, access, share, nil, syscall.OPEN_EXISTING, syscall.FILE_FLAG_BACKUP_SEMANTICS|openReparse, 0)
	if e != nil {
		return x, "", e
	}
	var i syscall.ByHandleFileInformation
	if e = syscall.GetFileInformationByHandle(h, &i); e != nil {
		syscall.CloseHandle(h)
		return x, "", e
	}
	if i.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		syscall.CloseHandle(h)
		return x, "", errors.New("reparse point rejected")
	}
	x = lockedEntry{h: h, path: path, dir: i.FileAttributes&syscall.FILE_ATTRIBUTE_DIRECTORY != 0}
	return x, fmt.Sprintf("%08x:%08x%08x", i.VolumeSerialNumber, i.FileIndexHigh, i.FileIndexLow), nil
}
func readLocked(h syscall.Handle) ([]byte, error) {
	buf := make([]byte, 65537)
	var n uint32
	if err := syscall.ReadFile(h, buf, &n, nil); err != nil {
		return nil, err
	}
	if n > 65536 {
		return nil, errors.New("marker too large")
	}
	return buf[:n], nil
}

func safeDelete(root, name, expectedID string, now time.Time, anchor tempAnchor) error {
	return safeProcess(root, name, expectedID, now, "", anchor)
}
func safeFinish(root, name, expectedID, expiry string, anchor tempAnchor) error {
	return safeProcess(root, name, expectedID, time.Time{}, expiry, anchor)
}
func safeProcess(root, name, expectedID string, now time.Time, finish string, temp tempAnchor) (result error) {
	abs, e := filepath.Abs(root)
	if e != nil {
		return e
	}
	abs = filepath.Clean(abs)
	// Lock each existing ancestor before opening its descendant so none can be renamed.
	vol := filepath.VolumeName(abs)
	current := vol + string(os.PathSeparator)
	parts := strings.Split(strings.TrimPrefix(abs, current), string(os.PathSeparator))
	var ancestors []lockedEntry
	defer func() {
		for i := len(ancestors) - 1; i >= 0; i-- {
			syscall.CloseHandle(ancestors[i].h)
		}
	}()
	x, _, e := openLocked(current, false)
	if e != nil {
		return e
	}
	ancestors = append(ancestors, x)
	for _, part := range parts {
		if part == "" {
			continue
		}
		current = filepath.Join(current, part)
		x, _, e = openLocked(current, false)
		if e != nil {
			return e
		}
		if !x.dir {
			syscall.CloseHandle(x.h)
			return errors.New("ancestor not directory")
		}
		ancestors = append(ancestors, x)
	}
	if e = verifyTempAnchor(temp); e != nil {
		return e
	}
	anchor, e := os.OpenRoot(abs)
	if e != nil {
		return e
	}
	defer anchor.Close()
	rootMark, _, e := openLocked(filepath.Join(abs, rootMarker), true)
	if e != nil {
		return e
	}
	defer syscall.CloseHandle(rootMark.h)
	if rootMark.dir {
		return errors.New("invalid root marker")
	}
	b, e := readLocked(rootMark.h)
	if e != nil || string(b) != rootContent {
		return errors.New("invalid root marker")
	}
	p := filepath.Join(abs, name)
	first, id, e := openLocked(p, true)
	if e != nil {
		return e
	}
	if !first.dir || id != expectedID {
		syscall.CloseHandle(first.h)
		return errors.New("item identity changed")
	}
	entries := []lockedEntry{first}
	defer func() {
		for _, v := range entries {
			if v.h != syscall.InvalidHandle {
				syscall.CloseHandle(v.h)
			}
		}
	}()
	if e = rejectNamedStreams(first.h); e != nil {
		return e
	}
	itemRoot, e := anchor.OpenRoot(name)
	if e != nil {
		return fmt.Errorf("open item root: %w", e)
	}
	defer itemRoot.Close()
	mark, _, e := openLocked(filepath.Join(p, itemMarker), true)
	if e != nil {
		return e
	}
	entries = append(entries, mark)
	if e = rejectNamedStreams(mark.h); e != nil {
		return e
	}
	if mark.dir {
		return errors.New("invalid item marker")
	}
	b, e = readLocked(mark.h)
	if e != nil {
		return e
	}
	var m metadata
	if json.Unmarshal(b, &m) != nil || m.Kind != "windows_setup_disposable_v1" || m.Name != name || m.ID != id {
		return errors.New("item marker changed")
	}
	receiptData := b
	if finish == "" {
		finished, _, err := openLocked(filepath.Join(p, finishMarker), true)
		if err != nil {
			return err
		}
		entries = append(entries, finished)
		if finished.dir {
			return errors.New("invalid finished manifest")
		}
		if err = rejectNamedStreams(finished.h); err != nil {
			return err
		}
		receiptData, err = readLocked(finished.h)
		if err != nil {
			return err
		}
		if json.Unmarshal(receiptData, &m) != nil || m.Kind != "windows_setup_disposable_v1" || m.Name != name || m.ID != id {
			return errors.New("invalid finished manifest")
		}
	}
	markerRemoved := false
	defer func() {
		if result == nil || !markerRemoved {
			return
		}
		if beforeRestoreHook != nil {
			beforeRestoreHook()
		}
		f, err := os.OpenFile(filepath.Join(p, itemMarker), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err == nil {
			_, err = f.Write(b)
			if closeErr := f.Close(); err == nil {
				err = closeErr
			}
		}
		if err != nil {
			result = fmt.Errorf("%w; restore ownership marker: %v", result, err)
		}
	}()
	if finish == "" {
		expiry, err := time.Parse(time.RFC3339, m.Expires)
		if err != nil || now.Before(expiry) || m.Nonce == "" {
			return errors.New("item active, expired invalid, or no manifest")
		}
	} else if m.Expires != "" {
		return errors.New("item already finished")
	}
	if afterMarkerReadHook != nil {
		afterMarkerReadHook()
	}
	var snapshot []manifestEntry
	var collect func(string) error
	collect = func(dir string) error {
		rel, e := filepath.Rel(p, dir)
		if e != nil {
			return e
		}
		f, e := itemRoot.Open(rel)
		if e != nil {
			return e
		}
		children, e := enumerateIDs(syscall.Handle(f.Fd()))
		f.Close()
		if e != nil {
			return fmt.Errorf("enumerate: %w", e)
		}
		if afterEnumerateHook != nil {
			afterEnumerateHook()
		}
		for _, child := range children {
			if dir == p && (child.name == itemMarker || child.name == finishMarker) {
				continue
			}
			q := filepath.Join(dir, child.name)
			ent, childID, e := openLocked(q, true)
			if e != nil {
				return e
			}
			if identityTestHook != nil {
				childID = identityTestHook(q, childID)
			}
			if !strings.HasSuffix(childID, fmt.Sprintf(":%016x", child.id)) {
				syscall.CloseHandle(ent.h)
				return errors.New("enumerated child identity changed")
			}
			entries = append(entries, ent)
			if e = rejectNamedStreams(ent.h); e != nil {
				return e
			}
			rel, err := filepath.Rel(p, q)
			if err != nil {
				return err
			}
			entry := manifestEntry{Path: filepath.ToSlash(rel), ID: childID, Dir: ent.dir}
			if !ent.dir {
				hash := sha256.New()
				buf := make([]byte, 65536)
				for {
					var n uint32
					if err := syscall.ReadFile(ent.h, buf, &n, nil); err != nil {
						return err
					}
					if n == 0 {
						break
					}
					entry.Size += int64(n)
					hash.Write(buf[:n])
				}
				entry.SHA256 = hex.EncodeToString(hash.Sum(nil))
			}
			snapshot = append(snapshot, entry)
			if ent.dir {
				if e = collect(q); e != nil {
					return e
				}
			}
		}
		return nil
	}
	if e = collect(p); e != nil {
		return e
	}
	if finish != "" {
		var nonce [32]byte
		if _, e = rand.Read(nonce[:]); e != nil {
			return e
		}
		m.Expires, m.Nonce, m.Manifest = finish, hex.EncodeToString(nonce[:]), snapshot
		encoded, err := json.Marshal(m)
		if err != nil {
			return err
		}
		if len(encoded) > 65536 {
			return errors.New("manifest too large")
		}
		fp, err := syscall.UTF16PtrFromString(filepath.Join(p, finishMarker))
		if err != nil {
			return err
		}
		fh, err := syscall.CreateFile(fp, syscall.GENERIC_WRITE, syscall.FILE_SHARE_READ, nil, syscall.CREATE_NEW, syscall.FILE_ATTRIBUTE_NORMAL|openReparse, 0)
		if err != nil {
			return err
		}
		defer syscall.CloseHandle(fh)
		var n uint32
		if finishWriteTestHook != nil {
			if err = syscall.WriteFile(fh, encoded[:1], &n, nil); err != nil {
				return err
			}
			if err = finishWriteTestHook(); err != nil {
				return err
			}
			return errors.New("unexpected test hook success")
		}
		if err = syscall.WriteFile(fh, encoded, &n, nil); err != nil {
			return err
		}
		if int(n) != len(encoded) {
			return errors.New("short marker write")
		}
		return syscall.FlushFileBuffers(fh)
	}
	if len(snapshot) != len(m.Manifest) {
		return errors.New("manifest entry count changed")
	}
	want := make(map[string]manifestEntry, len(m.Manifest))
	for _, v := range m.Manifest {
		if _, exists := want[v.Path]; exists {
			return errors.New("duplicate manifest entry")
		}
		want[v.Path] = v
	}
	for _, v := range snapshot {
		if expected, ok := want[v.Path]; !ok || expected != v {
			return errors.New("manifest entry changed")
		}
	}
	if len(m.Nonce) != 64 {
		return errors.New("invalid nonce")
	}
	if _, err := hex.DecodeString(m.Nonce); err != nil {
		return errors.New("invalid nonce")
	}
	receiptPath := filepath.Join(abs, ".windows_setup_cleanup_recovery_"+m.Nonce)
	rp, err := syscall.UTF16PtrFromString(receiptPath)
	if err != nil {
		return err
	}
	receipt, err := syscall.CreateFile(rp, syscall.GENERIC_READ|syscall.GENERIC_WRITE|deleteAccess, syscall.FILE_SHARE_READ, nil, syscall.CREATE_NEW, syscall.FILE_ATTRIBUTE_NORMAL|openReparse, 0)
	if err != nil {
		return fmt.Errorf("create recovery receipt: %w", err)
	}
	defer syscall.CloseHandle(receipt)
	var written uint32
	if err = syscall.WriteFile(receipt, receiptData, &written, nil); err != nil {
		return fmt.Errorf("write recovery receipt: %w", err)
	}
	if int(written) != len(receiptData) {
		return errors.New("short recovery receipt write")
	}
	if err = syscall.FlushFileBuffers(receipt); err != nil {
		return fmt.Errorf("flush recovery receipt: %w", err)
	}
	if beforeDeleteHook != nil {
		beforeDeleteHook()
	}
	// The handles, including all directories, remain open and deny write/delete sharing.
	// Delete children first, closing each marked handle before its parent.
	itemRoot.Close()
	for i := len(entries) - 1; i >= 0; i-- {
		flag := byte(1)
		ok, _, callErr := setFileInformationByHandle.Call(uintptr(entries[i].h), 4, uintptr(unsafe.Pointer(&flag)), 1)
		if ok == 0 {
			return fmt.Errorf("mark deletion %s: %w", entries[i].path, callErr)
		}
		if e = syscall.CloseHandle(entries[i].h); e != nil {
			return e
		}
		entries[i].h = syscall.InvalidHandle
		if i == 1 {
			markerRemoved = true
		}
	}
	flag := byte(1)
	ok, _, callErr := setFileInformationByHandle.Call(uintptr(receipt), 4, uintptr(unsafe.Pointer(&flag)), 1)
	if ok == 0 {
		return fmt.Errorf("remove recovery receipt: %w", callErr)
	}
	return nil
}

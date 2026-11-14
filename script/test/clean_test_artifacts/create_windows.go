//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

var ntCreateFile = syscall.NewLazyDLL("ntdll.dll").NewProc("NtCreateFile")
var rtlNtStatusToDosError = syscall.NewLazyDLL("ntdll.dll").NewProc("RtlNtStatusToDosError")

type unicodeString struct {
	Length, MaximumLength uint16
	Buffer                *uint16
}
type objectAttributes struct {
	Length                                       uint32
	RootDirectory                                syscall.Handle
	ObjectName                                   *unicodeString
	Attributes                                   uint32
	SecurityDescriptor, SecurityQualityOfService uintptr
}
type ioStatusBlock struct{ Status, Information uintptr }

var ntCreateFileTestHook func(*syscall.Handle, *ioStatusBlock) uintptr

func createRelativeDirectory(parent syscall.Handle, name string) (syscall.Handle, error) {
	if nativeCreateTestHook != nil {
		nativeCreateTestHook()
	}
	if !safeName(name) {
		return syscall.InvalidHandle, errors.New("invalid directory name")
	}
	u, err := syscall.UTF16FromString(name)
	if err != nil {
		return syscall.InvalidHandle, err
	}
	if len(u) > 32767 {
		return syscall.InvalidHandle, errors.New("directory name too long")
	}
	n := unicodeString{Length: uint16((len(u) - 1) * 2), MaximumLength: uint16(len(u) * 2), Buffer: &u[0]}
	a := objectAttributes{RootDirectory: parent, ObjectName: &n, Attributes: 0x40}
	a.Length = uint32(unsafe.Sizeof(a))
	h := syscall.InvalidHandle
	ios := ioStatusBlock{Status: 0x103}
	var status uintptr
	if ntCreateFileTestHook != nil {
		status = ntCreateFileTestHook(&h, &ios)
	} else {
		status, _, _ = ntCreateFile.Call(uintptr(unsafe.Pointer(&h)), 0x00100081, uintptr(unsafe.Pointer(&a)), uintptr(unsafe.Pointer(&ios)), 0, 0, uintptr(syscall.FILE_SHARE_READ), 2, 0x00200021, 0, 0)
	}
	if uint32(status) != 0 {
		if h != syscall.InvalidHandle && h != 0 {
			syscall.CloseHandle(h)
		}
		if int32(status) >= 0 {
			return syscall.InvalidHandle, fmt.Errorf("native create incomplete: %#x", uint32(status))
		}
		code, _, _ := rtlNtStatusToDosError.Call(status)
		return syscall.InvalidHandle, syscall.Errno(code)
	}
	if h == syscall.InvalidHandle || h == 0 {
		return syscall.InvalidHandle, errors.New("native create returned invalid handle")
	}
	if uint32(ios.Status) != 0 || ios.Information != 2 {
		syscall.CloseHandle(h)
		return syscall.InvalidHandle, errors.New("native create did not confirm creation")
	}
	return h, nil
}

func createOwnedDirectory(path, name string, root bool, anchor tempAnchor) error {
	parent := filepath.Dir(path)
	vol := filepath.VolumeName(parent)
	current := vol + string(os.PathSeparator)
	parts := strings.Split(strings.TrimPrefix(parent, current), string(os.PathSeparator))
	var held []lockedEntry
	defer func() {
		for i := len(held) - 1; i >= 0; i-- {
			syscall.CloseHandle(held[i].h)
		}
	}()
	lock := func(p string) error {
		x, _, e := openLocked(p, false)
		if e != nil {
			return e
		}
		if !x.dir {
			syscall.CloseHandle(x.h)
			return errors.New("parent is not directory")
		}
		held = append(held, x)
		return nil
	}
	if e := lock(current); e != nil {
		return e
	}
	for _, part := range parts {
		if part != "" {
			current = filepath.Join(current, part)
			if e := lock(current); e != nil {
				return e
			}
		}
	}
	if e := verifyTempAnchor(anchor); e != nil {
		return e
	}
	if !root {
		mark, _, e := openLocked(filepath.Join(parent, rootMarker), true)
		if e != nil {
			return e
		}
		defer syscall.CloseHandle(mark.h)
		b, e := readLocked(mark.h)
		if e != nil || mark.dir || string(b) != rootContent {
			return errors.New("invalid root marker")
		}
	}
	dir, e := createRelativeDirectory(held[len(held)-1].h, filepath.Base(path))
	if e != nil {
		return fmt.Errorf("atomic directory creation: %w", e)
	}
	defer syscall.CloseHandle(dir)
	var info syscall.ByHandleFileInformation
	if e = syscall.GetFileInformationByHandle(dir, &info); e != nil {
		return e
	}
	if info.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.FileAttributes&syscall.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return errors.New("invalid new directory")
	}
	if afterCreateDirectoryHook != nil {
		afterCreateDirectoryHook(path)
	}
	marker, data := rootMarker, []byte(rootContent)
	if !root {
		marker = itemMarker
		id := fmt.Sprintf("%08x:%08x%08x", info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow)
		data, e = json.Marshal(metadata{Kind: "windows_setup_disposable_v1", Name: name, ID: id})
		if e != nil {
			return e
		}
	}
	mp, e := syscall.UTF16PtrFromString(filepath.Join(path, marker))
	if e != nil {
		return e
	}
	mh, e := syscall.CreateFile(mp, syscall.GENERIC_WRITE, syscall.FILE_SHARE_READ, nil, syscall.CREATE_NEW, syscall.FILE_ATTRIBUTE_NORMAL|openReparse, 0)
	if e != nil {
		return e
	}
	defer syscall.CloseHandle(mh)
	var n uint32
	if e = syscall.WriteFile(mh, data, &n, nil); e != nil {
		return e
	}
	if int(n) != len(data) {
		return errors.New("short marker write")
	}
	return syscall.FlushFileBuffers(mh)
}

//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func canonicalTemp(raw string) (string, string, error) {
	current := filepath.VolumeName(raw) + string(os.PathSeparator)
	parts := strings.Split(strings.TrimPrefix(raw, current), string(os.PathSeparator))
	var held []lockedEntry
	defer func() {
		for i := len(held) - 1; i >= 0; i-- {
			syscall.CloseHandle(held[i].h)
		}
	}()
	var id string
	lock := func(path string) error {
		ent, identity, err := openLocked(path, false)
		if err != nil {
			return err
		}
		if !ent.dir {
			syscall.CloseHandle(ent.h)
			return fmt.Errorf("TEMP ancestor is not directory")
		}
		held = append(held, ent)
		id = identity
		return nil
	}
	if err := lock(current); err != nil {
		return "", "", err
	}
	for _, part := range parts {
		if part != "" {
			current = filepath.Join(current, part)
			if err := lock(current); err != nil {
				return "", "", err
			}
		}
	}
	resolved, err := filepath.EvalSymlinks(raw)
	if err != nil {
		return "", "", err
	}
	resolved, err = plainPath(resolved)
	if err != nil {
		return "", "", err
	}
	resolvedID, err := directoryIdentity(resolved)
	if err != nil {
		return "", "", err
	}
	if id != resolvedID {
		return "", "", fmt.Errorf("TEMP identity changed")
	}
	return resolved, id, nil
}

func verifyTempAnchor(anchor tempAnchor) error {
	id, err := directoryIdentity(anchor.path)
	if err != nil {
		return err
	}
	if id != anchor.id {
		return fmt.Errorf("TEMP identity changed")
	}
	return nil
}

func directoryIdentity(path string) (string, error) {
	p, e := syscall.UTF16PtrFromString(path)
	if e != nil {
		return "", e
	}
	h, e := syscall.CreateFile(p, 0, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE, nil, syscall.OPEN_EXISTING, syscall.FILE_FLAG_BACKUP_SEMANTICS|0x00200000, 0)
	if e != nil {
		return "", e
	}
	defer syscall.CloseHandle(h)
	var info syscall.ByHandleFileInformation
	if e = syscall.GetFileInformationByHandle(h, &info); e != nil {
		return "", e
	}
	if info.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.FileAttributes&syscall.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return "", fmt.Errorf("directory is reparse or not a directory")
	}
	return fmt.Sprintf("%08x:%08x%08x", info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow), nil
}

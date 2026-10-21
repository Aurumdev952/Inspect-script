//go:build windows

// PC-Inspection.exe - one-click launcher for the PC inspection.
//
// Put it on the flash disk next to config.json (and an optional drivers\
// folder). Double-clicking it:
//  1. asks Windows for admin rights (needed to install drivers / add Wi-Fi),
//  2. copies itself, config.json and drivers\ to C:\ProgramData\PC-Inspection
//     and restarts from there, so the flash disk can be removed right away,
//  3. unpacks the embedded PowerShell scripts to a temp folder and runs
//     Inspect-PC.ps1 (results are copied back to the flash disk at the end
//     if it is still plugged in),
//  4. keeps the window open so the inspector can read PASS/FAIL.
//
// Any extra command-line arguments are passed through to Inspect-PC.ps1
// (e.g. -Inspector "Jane" -NoUpload -SkipNetwork). --no-pause skips the
// final "Press Enter" prompt and --wait makes the flash-disk copy wait for
// the local copy to finish (both used by CI). --no-relocate runs straight
// from the flash disk.
package main

import (
	"bufio"
	"embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

//go:embed scripts/*.ps1
var scripts embed.FS

var version = "dev"

func main() {
	args := os.Args[1:]
	opt := options{}
	var psArgs []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--no-pause":
			opt.noPause = true
		case "--wait":
			opt.wait = true
		case "--no-relocate":
			opt.noRelocate = true
		case "--usb-root":
			if i+1 < len(args) {
				opt.usbRoot = args[i+1]
				i++
			}
		default:
			psArgs = append(psArgs, args[i])
		}
	}

	code, pause := run(args, psArgs, opt)
	if pause && !opt.noPause {
		fmt.Print("\nPress Enter to close this window...")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(code)
}

type options struct {
	noPause, wait, noRelocate bool
	usbRoot                   string
}

// localDir is where the tool copies itself so the flash disk can be
// removed while the inspection keeps running.
func localDir() string {
	pd := os.Getenv("ProgramData")
	if pd == "" {
		pd = `C:\ProgramData`
	}
	return filepath.Join(pd, "PC-Inspection")
}

// run returns the exit code and whether to show the final "Press Enter".
func run(allArgs, psArgs []string, opt options) (int, bool) {
	fmt.Printf("PC Inspection %s\n", version)

	exe, err := os.Executable()
	if err != nil {
		fmt.Println("Cannot find my own location:", err)
		return 1, true
	}
	root := filepath.Dir(exe)

	if !isAdmin() {
		fmt.Println("Asking for administrator rights (click Yes)...")
		if err := relaunchAsAdmin(exe, allArgs, root); err != nil {
			fmt.Println("Could not get administrator rights:", err)
			fmt.Println("Right-click PC-Inspection.exe and choose 'Run as administrator'.")
			return 1, true
		}
		// The elevated copy opens its own window; this one can go away.
		return 0, false
	}

	tmp, err := os.MkdirTemp("", "pc-inspection-")
	if err != nil {
		fmt.Println("Cannot create temp folder:", err)
		return 1, true
	}
	defer os.RemoveAll(tmp)

	entries, _ := scripts.ReadDir("scripts")
	for _, e := range entries {
		data, _ := scripts.ReadFile("scripts/" + e.Name())
		if err := os.WriteFile(filepath.Join(tmp, e.Name()), data, 0o644); err != nil {
			fmt.Println("Cannot write script:", err)
			return 1, true
		}
	}

	local := localDir()
	if !opt.noRelocate && !strings.EqualFold(filepath.Clean(root), filepath.Clean(local)) {
		return relocate(exe, root, local, tmp, psArgs, opt)
	}

	ps := powershellPath()
	cmdArgs := []string{
		"-NoProfile", "-ExecutionPolicy", "Bypass",
		"-File", filepath.Join(tmp, "Inspect-PC.ps1"),
		"-FlashRoot", root,
	}
	if opt.usbRoot != "" {
		cmdArgs = append(cmdArgs, "-UsbRoot", opt.usbRoot)
	}
	cmd := exec.Command(ps, append(cmdArgs, psArgs...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Dir = root
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			// 2 = inspection ran fine but the PC FAILED the spec.
			return ee.ExitCode(), true
		}
		fmt.Println("Could not start PowerShell:", err)
		return 1, true
	}
	return 0, true
}

// powershellPath returns the Windows PowerShell 5.1 that ships with Windows.
func powershellPath() string {
	ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if _, err := os.Stat(ps); err != nil {
		return "powershell.exe"
	}
	return ps
}

// relocate copies the exe, config.json and the inspector name from the flash
// disk to this PC, lets Prepare-Local.ps1 copy only the driver this PC needs,
// then restarts from the local copy in the same window and exits - nothing
// keeps the flash disk busy after that.
func relocate(exe, usb, local, scriptsDir string, psArgs []string, opt options) (int, bool) {
	fmt.Println("Copying the tool to this PC ...")
	if err := os.MkdirAll(local, 0o755); err != nil {
		fmt.Println("Cannot create", local, ":", err)
		return 1, true
	}
	copies := []struct{ src, dst string }{
		{exe, filepath.Join(local, "PC-Inspection.exe")},
		{filepath.Join(usb, "config.json"), filepath.Join(local, "config.json")},
		{filepath.Join(usb, "inspector-name.txt"), filepath.Join(local, "inspector-name.txt")},
	}
	for _, c := range copies {
		if err := copyFile(c.src, c.dst); err != nil && !os.IsNotExist(err) {
			fmt.Println("Copy failed:", err)
			return 1, true
		}
	}

	prep := exec.Command(powershellPath(), "-NoProfile", "-ExecutionPolicy", "Bypass",
		"-File", filepath.Join(scriptsDir, "Prepare-Local.ps1"), "-UsbRoot", usb, "-LocalDir", local)
	prep.Stdin, prep.Stdout, prep.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := prep.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 3 {
			// Damaged driver files: the script already explained how to fix it.
			return 3, true
		}
		fmt.Println("Preparing the driver failed:", err)
		return 1, true
	}

	fmt.Println()
	fmt.Println("=============================================================")
	fmt.Println("  Copied to this PC. You can REMOVE THE FLASH DISK now -")
	fmt.Println("  the inspection keeps running from this PC.")
	fmt.Println("=============================================================")

	args := append([]string{"--usb-root", usb}, psArgs...)
	if opt.noPause {
		args = append(args, "--no-pause")
	}
	child := exec.Command(filepath.Join(local, "PC-Inspection.exe"), args...)
	child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
	child.Dir = local
	if err := child.Start(); err != nil {
		fmt.Println("Could not start the local copy:", err)
		return 1, true
	}
	if opt.wait {
		if err := child.Wait(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				return ee.ExitCode(), false
			}
		}
	}
	// The child keeps this console window open; this process (running
	// from the flash disk) exits now.
	return 0, false
}

// copyFile copies src to dst, skipping it when dst already has the same
// size and modification time (so a second run on the same PC is quick).
func copyFile(src, dst string) error {
	si, err := os.Stat(src)
	if err != nil {
		return err
	}
	if di, err := os.Stat(dst); err == nil && di.Size() == si.Size() && di.ModTime().Equal(si.ModTime()) {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	os.Remove(dst)
	if err := os.Rename(tmp, dst); err != nil {
		return err
	}
	return os.Chtimes(dst, si.ModTime(), si.ModTime())
}

// isAdmin: opening the raw physical disk only works for an elevated process.
func isAdmin() bool {
	f, err := os.Open(`\\.\PHYSICALDRIVE0`)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

func relaunchAsAdmin(exe string, args []string, dir string) error {
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = syscall.EscapeArg(a)
	}
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(exe)
	params, _ := syscall.UTF16PtrFromString(strings.Join(quoted, " "))
	cwd, _ := syscall.UTF16PtrFromString(dir)

	shell32 := syscall.NewLazyDLL("shell32.dll")
	shellExecute := shell32.NewProc("ShellExecuteW")
	const swShowNormal = 1
	r, _, _ := shellExecute.Call(0,
		uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(file)),
		uintptr(unsafe.Pointer(params)), uintptr(unsafe.Pointer(cwd)), swShowNormal)
	if r <= 32 {
		return fmt.Errorf("ShellExecute error code %d (UAC cancelled?)", r)
	}
	return nil
}

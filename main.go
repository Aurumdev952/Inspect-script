//go:build windows

// PC-Inspection.exe - one-click launcher for the PC inspection.
//
// Put it on the flash disk next to config.json (and an optional drivers\
// folder). Double-clicking it:
//  1. asks Windows for admin rights (needed to install drivers / add Wi-Fi),
//  2. unpacks the embedded PowerShell scripts to a temp folder,
//  3. runs Inspect-PC.ps1 with the flash disk folder as -FlashRoot,
//  4. keeps the window open so the inspector can read PASS/FAIL.
//
// Any extra command-line arguments are passed through to Inspect-PC.ps1
// (e.g. -Inspector "Jane" -NoUpload -SkipNetwork). --no-pause skips the
// final "Press Enter" prompt (used by CI).
package main

import (
	"bufio"
	"embed"
	"fmt"
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
	noPause := false
	var psArgs []string
	for _, a := range args {
		if a == "--no-pause" {
			noPause = true
			continue
		}
		psArgs = append(psArgs, a)
	}

	code := run(args, psArgs)
	if !noPause {
		fmt.Print("\nPress Enter to close this window...")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(code)
}

func run(allArgs, psArgs []string) int {
	fmt.Printf("PC Inspection %s\n", version)

	exe, err := os.Executable()
	if err != nil {
		fmt.Println("Cannot find my own location:", err)
		return 1
	}
	flashRoot := filepath.Dir(exe)

	if !isAdmin() {
		fmt.Println("Asking for administrator rights (click Yes)...")
		if err := relaunchAsAdmin(exe, allArgs, flashRoot); err != nil {
			fmt.Println("Could not get administrator rights:", err)
			fmt.Println("Right-click PC-Inspection.exe and choose 'Run as administrator'.")
			return 1
		}
		// The elevated copy opens its own window; this one can go away.
		os.Exit(0)
	}

	tmp, err := os.MkdirTemp("", "pc-inspection-")
	if err != nil {
		fmt.Println("Cannot create temp folder:", err)
		return 1
	}
	defer os.RemoveAll(tmp)

	entries, _ := scripts.ReadDir("scripts")
	for _, e := range entries {
		data, _ := scripts.ReadFile("scripts/" + e.Name())
		if err := os.WriteFile(filepath.Join(tmp, e.Name()), data, 0o644); err != nil {
			fmt.Println("Cannot write script:", err)
			return 1
		}
	}

	ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if _, err := os.Stat(ps); err != nil {
		ps = "powershell.exe"
	}
	cmdArgs := append([]string{
		"-NoProfile", "-ExecutionPolicy", "Bypass",
		"-File", filepath.Join(tmp, "Inspect-PC.ps1"),
		"-FlashRoot", flashRoot,
	}, psArgs...)
	cmd := exec.Command(ps, cmdArgs...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Dir = flashRoot
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			// 2 = inspection ran fine but the PC FAILED the spec.
			return ee.ExitCode()
		}
		fmt.Println("Could not start PowerShell:", err)
		return 1
	}
	return 0
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

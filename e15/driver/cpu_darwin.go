//go:build darwin

package main

import "syscall"

// selfCPU reads this process's cumulative user/system CPU with getrusage(RUSAGE_SELF). macOS has
// no /proc; this exists so the laptop control check (A2) can run.
func selfCPU() (utimeMs, stimeMs int64, err error) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, 0, err
	}
	ms := func(tv syscall.Timeval) int64 { return int64(tv.Sec)*1000 + int64(tv.Usec)/1000 }
	return ms(ru.Utime), ms(ru.Stime), nil
}

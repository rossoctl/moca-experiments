//go:build linux

package main

import "os"

// selfCPU reads this process's cumulative utime/stime from /proc/self/stat.
func selfCPU() (utimeMs, stimeMs int64, err error) {
	b, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		return 0, 0, err
	}
	return parseProcStat(string(b))
}

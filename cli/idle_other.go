//go:build !darwin

package main

import "time"

func hidIdle() (time.Duration, bool) { return 0, false }

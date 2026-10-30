/*
** Copyright (C) 2001-2026 Zabbix SIA
**
** Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
** documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
** rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
** permit persons to whom the Software is furnished to do so, subject to the following conditions:
**
** The above copyright notice and this permission notice shall be included in all copies or substantial portions
** of the Software.
**
** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
** WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
** COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
** TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
** SOFTWARE.
**/

package plugin

// revive:disable:max-public-structs

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"golang.zabbix.com/sdk/errs"
)

// DefaultPluginTimeout is default value for testing.
const DefaultPluginTimeout = 30 // seconds

// UnsupportedMetricError used to return that key is not supported.
//
//nolint:errname,gochecknoglobals //requires zabbix main repo fixes
var UnsupportedMetricError = errs.New("unsupported item key")

// Collector - interface for periodical metric collection.
type Collector interface {
	Collect() error
	Period() int
}

// Exporter - interface for exporting collected metrics.
type Exporter interface {
	// Export method exports data based on the key 'key' and its parameters 'params'.
	Export(
		key string, params []string, context ContextProvider,
	) (any, error)
}

// Runner - interface for managing background processes.
type Runner interface {
	// Start method activates plugin.
	Start()
	// Stop method deactivates plugin.
	Stop()
}

// Watcher - interface for fully custom monitoring.
type Watcher interface {
	// Watch method instructs plugin to watch for events based on item configuration.
	Watch(items []*Item, context ContextProvider)
}

// Configurator - interface for plugin configuration in agent conf files.
type Configurator interface {
	// Configure method passes global and private plugin configuration after it has been activated.
	Configure(globalOptions *GlobalOptions, privateOptions any)
	// Validate method validates private plugin configuration during agent startup.
	Validate(privateOptions any) error
}

// ResultWriter defines the contract for buffering and submitting collected check results.
type ResultWriter interface {
	Write(result *Result)
	Flush()
	SlotsAvailable() int
	PersistSlotsAvailable() int
}

// Meta holds thread-safe stateful metadata for an item that persists across checks.
type Meta struct {
	lastLogsize atomic.Uint64
	mtime       atomic.Int32
	Data        any
}

// ContextProvider provides the execution context and dependencies for a data collection task.
//
//nolint:interfacebloat
type ContextProvider interface {
	context.Context
	ClientID() uint64
	ItemID() uint64
	Output() ResultWriter
	Meta() *Meta
	GlobalRegexp() RegexpMatcher
	Timeout() int
	LegacyTimeout() bool
	Delay() string
}

type contextWithStartedTimeout struct {
	ContextProvider

	deadline time.Time
	err      error
	done     chan struct{}
	mu       sync.Mutex
	timeout  int
}

// Result encapsulates the data and metadata collected from a single item check.
type Result struct {
	Itemid uint64
	Value  *string

	// additional windows eventlog fields
	EventSource    *string
	EventID        *int
	EventTimestamp *int
	EventSeverity  *int

	Ts          time.Time
	Error       error
	LastLogsize *uint64
	Mtime       *int
	Persistent  bool
}

// Item represents a configured data collection task with its parameters.
type Item struct {
	Itemid      uint64
	Key         string
	Delay       string
	LastLogsize *uint64
	Mtime       *int
	Timeout     int
}

// GlobalOptions are global agent configuration parameters that can be accessed by plugins.
// In most cases it's recommended to allow plugins overriding global configuration parameters
// they are using with plugin specific parameters.
type GlobalOptions struct {
	Timeout  int    `json:"Timeout"`  //nolint:tagliatelle
	SourceIP string `json:"SourceIP"` //nolint:tagliatelle
}

// RegexpMatcher defines the interface for performing regular expression matches.
type RegexpMatcher interface {
	Match(value, pattern string, mode int, outputTemplate *string) (match bool, output string)
}

// SetLastLogsize sets lastLogSize.
func (m *Meta) SetLastLogsize(value uint64) {
	m.lastLogsize.Store(value)
}

// LastLogsize returns lastLogSize.
func (m *Meta) LastLogsize() uint64 {
	return m.lastLogsize.Load()
}

// SetMtime sets Mtime.
func (m *Meta) SetMtime(value int32) {
	m.mtime.Store(value)
}

// Mtime returns Mtime.
func (m *Meta) Mtime() int32 {
	return m.mtime.Load()
}

// Deadline implements the context.Context interface.
func (c *contextWithStartedTimeout) Deadline() (time.Time, bool) {
	return c.deadline, true
}

// Done implements the context.Context interface.
func (c *contextWithStartedTimeout) Done() <-chan struct{} {
	return c.done
}

// Err implements the context.Context interface.
func (c *contextWithStartedTimeout) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.err
}

// Timeout implements the context.Context interface.
func (c *contextWithStartedTimeout) Timeout() int {
	return c.timeout
}

// StartTimeout begins counting down timeout.
//
//nolint:ireturn
func StartTimeout(provider ContextProvider, currentTime time.Time) ContextProvider {
	newContext := &contextWithStartedTimeout{
		ContextProvider: provider,
		deadline:        currentTime.Add(time.Duration(provider.Timeout()) * time.Second),
		done:            make(chan struct{}),
		timeout:         provider.Timeout(),
	}

	time.AfterFunc(time.Until(newContext.deadline), func() {
		newContext.mu.Lock()
		defer newContext.mu.Unlock()

		if newContext.err == nil {
			newContext.err = context.DeadlineExceeded
			close(newContext.done)
		}
	})

	return newContext
}

// OverrideTimeout decreases timeout and begins counting down.
// If the provider being passed in has a smaller timeout than the new timeout,
// this function will return the passed in provider as is, otherwise it will
// create a new provider with the smaller timeout, wrapping the passed in
// provider.
// So effectively this function can be used to only decrease the timeout of
// a context.
//
//nolint:ireturn
func OverrideTimeout(provider ContextProvider, currentTime time.Time, newTimeout int) ContextProvider {
	newDeadline := currentTime.Add(time.Duration(newTimeout) * time.Second)

	previousDeadline, ok := provider.Deadline()
	if ok && previousDeadline.Before(newDeadline) {
		return provider
	}

	newContext := &contextWithStartedTimeout{
		ContextProvider: provider,
		deadline:        newDeadline,
		done:            make(chan struct{}),
		timeout:         newTimeout,
	}

	time.AfterFunc(time.Until(newContext.deadline), func() {
		newContext.mu.Lock()
		defer newContext.mu.Unlock()

		if newContext.err == nil {
			newContext.err = context.DeadlineExceeded
			close(newContext.done)
		}
	})

	return newContext
}

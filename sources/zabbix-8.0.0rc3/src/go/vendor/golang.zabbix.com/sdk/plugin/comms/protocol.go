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

package comms

// revive:disable:max-public-structs

import "golang.zabbix.com/sdk/plugin"

// ProtocolVersion specifies the version of the plugin protocol for compatibility checks.
const ProtocolVersion = "6.4.0"

// NonRequiredID is a special value used for the ID field in messages that do not require a unique identifier.
const NonRequiredID = 0

const (
	// Exporter is a bit flag indicating the plugin implements the Exporter interface for metric collection.
	Exporter = 1 << iota
	// Configurator is a bit flag indicating the plugin implements the Configurator interface for dynamic configuration.
	Configurator
	// Runner is a bit flag indicating the plugin implements the Runner interface for long-running tasks.
	Runner
)

//nolint:revive
const (
	LogRequestType = iota + 1
	RegisterRequestType
	RegisterResponseType
	StartRequestType
	TerminateRequestType
	ExportRequestType
	ExportResponseType
	ConfigureRequestType
	ValidateRequestType
	ValidateResponseType
	PeriodRequestType
	PeriodResponseType
)

//nolint:gochecknoglobals
var toString = map[request]string{
	LogRequestType:       "Log Request",
	RegisterRequestType:  "Register Request",
	RegisterResponseType: "Register Response",
	StartRequestType:     "Start Request",
	TerminateRequestType: "Terminate Request",
	ExportRequestType:    "Export Request",
	ExportResponseType:   "Export Response",
	ConfigureRequestType: "Configure Request",
	ValidateRequestType:  "Validate Request",
	ValidateResponseType: "Validate Response",
	PeriodRequestType:    "Period Request",
	PeriodResponseType:   "Period Response",
}

type request int

// Common defines the shared header fields present in all plugin messages.
type Common struct {
	Id   uint32 `json:"id"` //nolint:revive
	Type uint32 `json:"type"`
}

// LogRequest defines the structure for a message sent to be recorded as a log entry.
type LogRequest struct {
	Common
	Severity uint32 `json:"severity"`
	Message  string `json:"message"`
}

// RegisterRequest defines the initial handshake message from a plugin to the agent.
type RegisterRequest struct {
	Common
	ProtocolVersion string `json:"version"`
}

// RegisterResponse defines the structure of a response to a plugin registration request.
type RegisterResponse struct {
	Common
	Name       string   `json:"name"`
	Metrics    []string `json:"metrics,omitempty"`
	Interfaces uint32   `json:"interfaces,omitempty"`
	Error      string   `json:"error,omitempty"`
}

// ValidateRequest defines the structure for a request to validate plugin options.
type ValidateRequest struct {
	Common
	PrivateOptions any `json:"private_options,omitempty"`
}

// ValidateResponse defines the structure of a response to a validation request.
type ValidateResponse struct {
	Common
	Error string `json:"error,omitempty"`
}

// StartRequest defines the structure for a request to start the plugin's data collection.
type StartRequest struct {
	Common
}

// TerminateRequest defines the structure for a request to stop the plugin's execution.
type TerminateRequest struct {
	Common
}

// ExportRequest defines the structure for a request to export a single metric value.
type ExportRequest struct {
	Common
	Key           string   `json:"key"`
	Params        []string `json:"parameters,omitempty"`
	Timeout       int      `json:"timeout"`
	LegacyTimeout *bool    `json:"legacy_timeout"`
}

// ExportResponse defines the structure of a response containing an exported metric value.
type ExportResponse struct {
	Common
	Value any    `json:"value,omitempty"`
	Error string `json:"error,omitempty"`
}

// ConfigureRequest defines the structure for a request to configure a plugin with global and private options.
type ConfigureRequest struct {
	Common
	GlobalOptions  *plugin.GlobalOptions `json:"global_options"`
	PrivateOptions any                   `json:"private_options,omitempty"`
}

// GetRequestName converts a numeric request type identifier to its string representation.
func GetRequestName(reqType uint32) string {
	return toString[request(reqType)]
}

// ImplementsConfigurator checks if the plugin interface flags include the Configurator capability.
func ImplementsConfigurator(in uint32) bool {
	return in&Configurator != 0
}

// ImplementsExporter checks if the plugin interface flags include the Exporter capability.
func ImplementsExporter(in uint32) bool {
	return in&Exporter != 0
}

// ImplementsRunner checks if the plugin interface flags include the Runner capability.
func ImplementsRunner(in uint32) bool {
	return in&Runner != 0
}

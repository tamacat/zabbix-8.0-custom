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

package itemutil

import (
	"bytes"

	"golang.zabbix.com/sdk/errs"
)

const (
	paramListStart = '['
	paramListEnd   = ']'
	paramSeparator = ','
	paramQuote     = '"'
	paramSpace     = ' '
)

var errInvalidKey = errs.New("Invalid item key format.")
var errInvalidAlias = errs.New("Invalid item alias format.")

//nolint:gocyclo,cyclop
func isKeyChar(c byte, wildcard bool) bool {
	switch {
	case c >= 'a' && c <= 'z':
		return true
	case c >= 'A' && c <= 'Z':
		return true
	case c >= '0' && c <= '9':
		return true
	case c == '.' || c == '-' || c == '_':
		return true
	case wildcard && c == '*':
		return true
	default:
		return false
	}
}

// parseQuotedParam parses item key quoted parameter "..." and returns
// the parsed parameter (including quotes, but without whitespace outside quotes)
// and the data after the parameter (skipping also whitespace after closing quotes).
func parseQuotedParam(data []byte) ([]byte, []byte, error) {
	var previousByte byte

	for i, c := range data[1:] {
		if c == paramQuote && previousByte != '\\' {
			i += 2
			param := data[:i]

			remainder := data[i:]

			return param, remainder, nil
		}

		previousByte = c
	}

	return nil, nil, errs.New("unterminated quoted string")
}

// parseUnquotedParam parses item key normal parameter (any combination of any characters except ',' and ']',
// including trailing whitespace) and returns the parsed parameter and the data after the parameter.
func parseUnquotedParam(data []byte) ([]byte, []byte, error) {
	var param, remainder []byte

	for i, c := range data {
		if c == paramSeparator || c == paramListEnd {
			param = data[:i]
			remainder = data[i:]

			return param, remainder, nil
		}
	}

	return []byte{}, []byte{}, errs.New("unterminated parameter")
}

// parseNextArrayElement parses a single element from within an array.
// It handles quoted and unquoted parameters and returns the remainder of the
// slice after the element and any error.
func parseNextArrayElement(
	data []byte,
) ([]byte, error) {
	var err error
	// This switch contains the logic for parsing one element.
	switch data[0] {
	case paramQuote:
		// The parameter is quoted.
		_, data, err = parseQuotedParam(data)
	case paramListStart:
		// Nested arrays are not allowed.
		return nil, errs.New("nested arrays are not supported")
	default:
		// The parameter is unquoted. This also handles empty parameters
		// like in "[,p2]" or "[p1,,p3]".
		_, data, err = parseUnquotedParam(data)
	}

	if err != nil {
		return nil, err
	}

	return data, nil
}

// parseArrayParam parses item key array parameter [...] and returns.
// returns parameter, remainder and error
//
//nolint:cyclop
func parseArrayParam(data []byte) ([]byte, []byte, error) {
	if len(data) == 0 || data[0] != paramListStart {
		return nil, nil, errs.New("invalid array parameter: must start with '['")
	}

	// remove leading '['
	remaining := data[1:]

	for {
		remaining = bytes.TrimLeft(remaining, " ")

		// If we've run out of bytes without finding the closing ']', it's an error.
		if len(remaining) == 0 {
			return nil, nil, errs.New("unterminated array parameter")
		}

		// Check if we're at the end of the array. This also handles an empty array "[]".
		if remaining[0] == paramListEnd {
			pos := len(data) - len(remaining)

			param := data[:pos+1]
			remainder := remaining[1:]

			return param, remainder, nil
		}

		// If we're not at the end, we must be at the start of a new parameter.
		// After parsing a parameter, we expect a comma, so if we find a comma
		// here, it implies an empty parameter (e.g., `[,p2]` or `[p1,,p3]`).
		// This is valid and will be handled by parseUnquotedParam.
		var err error
		remaining, err = parseNextArrayElement(remaining)

		if err != nil {
			return nil, nil, err
		}

		// Handle what comes after the parameter
		remaining = bytes.TrimLeft(remaining, " ")
		if len(remaining) == 0 {
			return nil, nil, errs.New("unterminated array parameter")
		}

		switch remaining[0] {
		case paramSeparator:
			remaining = remaining[1:]

			continue
		case paramListEnd:
			continue
		default:
			return nil, nil, errs.New("expected ',' or ']' after array parameter")
		}
	}
}

// unquoteParam unquotes quoted parameter by removing enclosing double quotes '"' and
// unescaping '\"' escape sequences.
func unquoteParam(data []byte) []byte {
	param := make([]byte, 0, len(data))

	var last byte

	for _, c := range data[1:] {
		switch c {
		case paramQuote:
			if last != '\\' {
				return param
			}

			param = append(param, c)
		case '\\':
			if last == '\\' {
				param = append(param, '\\')
			}
		default:
			if last == '\\' {
				param = append(param, '\\')
			}

			param = append(param, c)
		}

		last = c
	}

	return param
}

// expandArray processes array parameter data by removing enclosing brackets
// and normalizing whitespace around array elements.
func expandArray(arrayData []byte) []byte {
	// Initialize result slice with capacity matching input size for efficiency
	expandedParams := make([]byte, 0, len(arrayData))

	// removing leading "["
	remainingData := arrayData[1:]

	for len(remainingData) > 0 {
		var currentParam []byte
		currentParam, remainingData = findNextParameter(remainingData)

		expandedParams = append(expandedParams, currentParam...)

		// Check if we've reached the end of the array (']' character)
		if len(remainingData) > 0 && remainingData[0] == paramListEnd {
			break
		}

		// Add separator between parameters and continue
		if len(remainingData) > 0 {
			expandedParams = append(expandedParams, paramSeparator)
			remainingData = remainingData[1:] // Move past the current separator
		}
	}

	return expandedParams
}

// Helper function to extract the next parameter from the data.
func findNextParameter(data []byte) ([]byte, []byte) {
	var param, remaining []byte

	// Skip leading whitespace to find the actual parameter start
	for i, char := range data {
		switch char {
		case paramSpace:
			continue // Skip whitespace
		case paramQuote:
			// Handle quoted parameter (e.g., "quoted string")
			param, remaining, _ = parseQuotedParam(data[i:]) //nolint:errcheck
		default:
			// Handle unquoted parameter
			param, remaining, _ = parseUnquotedParam(data[i:]) //nolint:errcheck
		}

		remaining = bytes.TrimLeft(remaining, " ")

		return param, remaining
	}

	return nil, data
}

// parseParam parses single item key parameter.
func parseParam(data []byte) ([]byte, []byte, error) {
	var param, remainder []byte

	var err error

	for i, c := range data {
		switch c {
		case paramSpace:
			continue
		case paramQuote:
			param, remainder, err = parseQuotedParam(data[i:])
			if err == nil {
				param = unquoteParam(param)
			}
		case paramListStart:
			param, remainder, err = parseArrayParam(data[i:])
			if err == nil {
				param = expandArray(param)
			}
		case paramListEnd, paramSeparator:
			param = data[i:i]
			remainder = data[i:]
		default:
			param, remainder, err = parseUnquotedParam(data[i:])
		}

		remainder = bytes.Trim(remainder, " ")

		return param, remainder, err
	}

	return []byte{}, []byte{}, errs.New("unterminated parameter list")
}

// parseParams parses item key parameters and returns parameters, remainder and error.
// Format: key[param1,param2,param3]remainder.
func parseParams(data []byte) ([]string, []byte, error) {
	// Validate opening bracket
	if data[0] != paramListStart {
		return nil, nil, errs.New("key name must be followed by '['")
	}

	if len(data) == 1 {
		return nil, nil, errs.New("unterminated parameter list")
	}

	var (
		remainder []byte
		param     []byte
		err       error
		params    []string
	)

	// Skip opening bracket
	currentRemainder := data[1:]

	for len(currentRemainder) > 0 {
		// Parse next parameter
		param, currentRemainder, err = parseParam(currentRemainder)
		if err != nil {
			return nil, nil, err
		}
		// Add new parameter to total parameters list
		params = append(params, string(param))

		if len(currentRemainder) == 0 {
			return nil, nil, errs.New("key parameters ended unexpectedly")
		}

		// Check for end of parameter list
		if currentRemainder[0] == paramListEnd {
			// Save remainder after closing bracket
			if len(currentRemainder) > 1 {
				remainder = currentRemainder[1:]
			}

			break
		}

		// Expect parameter separator after previous param
		if currentRemainder[0] != paramSeparator {
			return nil, nil, errs.New("invalid parameter separator")
		}

		// Remove separator
		currentRemainder = currentRemainder[1:]
	}

	// Check if we failed to find a closing bracket
	if len(currentRemainder) == 0 {
		return nil, nil, errs.New("unterminated parameter list")
	}

	return params, remainder, nil
}

// parseKey accepts raw key (f.e. some.key[arg1, arg2]) and returns key, arguments and error.
func parseKey(data []byte, wildcard bool) (string, []string, error) {
	// iterating over key to find arguments and verify that it is a somewhat valid key
	for i, c := range data {
		// searching for invalid char (that cannot be part of the key)
		if isKeyChar(c, wildcard) {
			continue
		}

		// key has to consist of at least one valid character, mostly useless check, just saves some computing power
		if i == 0 {
			return "", nil, errInvalidKey
		}

		// finishing parsing if found some non-compliant character that does not start argument list
		if c != paramListStart {
			return "", nil, errInvalidKey
		}

		// argument list start was found, and it has to end with a closing bracket without any remainder
		if data[len(data)-1] != paramListEnd {
			return "", nil, errInvalidKey
		}

		// we found a start of arguments list [arg1, arg2] part '['
		params, remainder, err := parseParams(data[i:])
		if err != nil || len(remainder) > 0 {
			return "", params, errInvalidKey
		}

		key := string(data[:i])

		return key, params, nil
	}

	key := string(data)

	return key, nil, nil
}

// parseAlias searches for invalid structure in the first part of name[arg]:key pattern.
func parseAlias(data []byte, wildcard bool) ([]byte, error) {
	// iterating over key to find arguments and verify that it is a somewhat valid key
	for i, c := range data {
		// searching for invalid char (that cannot be part of the key)
		if isKeyChar(c, wildcard) {
			continue
		}

		// key has to consist of at least one valid character, mostly useless check, just saves some computing power
		if i == 0 {
			return nil, errInvalidKey
		}

		// finishing parsing if found some non-compliant character that does not separate alias from the key
		if c == ':' {
			remainder := data[i:]

			return remainder, nil
		}

		// we found a start of arguments list [arg1, arg2] part '[' and search if the key is valid
		if c == paramListStart {
			_, remainder, err := parseParams(data[i:])
			if err != nil {
				return remainder, errInvalidKey
			}

			return remainder, nil
		}

		// we stumbled into unknown character
		return nil, errInvalidKey
	}

	return nil, errInvalidKey
}

func parseMetricKey(text string, wildcard bool) (string, []string, error) {
	if text == "" {
		return "", nil, errInvalidKey
	}

	key, params, err := parseKey([]byte(text), wildcard)
	if err != nil {
		return "", nil, err
	}

	return key, params, nil
}

// ParseKey parses item key in format key[param1, param2, ...] and returns
// the parsed key and parameters.
func ParseKey(text string) (string, []string, error) {
	return parseMetricKey(text, false)
}

// ParseWildcardKey parses item key in format key[param1, param2, ...] and returns
// the parsed key and parameters.
func ParseWildcardKey(text string) (string, []string, error) {
	return parseMetricKey(text, true)
}

// ParseAlias parses Alias in format name:key and returns the name
// and the key separately without changes.
func ParseAlias(text string) (string, string, error) {
	remainder, err := parseAlias([]byte(text), false)
	if err != nil {
		return "", "", err
	}

	if len(remainder) < 2 {
		return "", "", errInvalidAlias
	}

	// test if key is valid (without ':' in the beginning)
	_, _, err = parseKey(remainder[1:], false)
	if err != nil {
		return "", "", err
	}

	alias := text[:len(text)-len(remainder)] // keeping the alias without the key
	key := string(remainder[1:])             // remove ":" from the key

	return alias, key, nil
}

func mustQuote(param string) bool {
	if param != "" && (param[0] == paramQuote || param[0] == paramSpace) {
		return true
	}

	for _, b := range param {
		switch b {
		case paramSeparator, paramListEnd:
			return true
		}
	}

	return false
}

func quoteParam(buf *bytes.Buffer, param string) {
	buf.WriteByte(paramQuote)

	for _, b := range param {
		if b == paramQuote {
			buf.WriteByte('\\')
		}

		buf.WriteRune(b)
	}

	buf.WriteByte(paramQuote)
}

// MakeKey combines key and params into one key with params.
func MakeKey(key string, params []string) string {
	buf := bytes.Buffer{}
	buf.WriteString(key)

	if len(params) > 0 {
		buf.WriteByte(paramListStart)

		for i, p := range params {
			if i != 0 {
				buf.WriteByte(paramSeparator)
			}

			if !mustQuote(p) {
				buf.WriteString(p)
			} else {
				quoteParam(&buf, p)
			}
		}

		buf.WriteByte(paramListEnd)
	}

	return buf.String()
}

// CompareKeysParams compares either key and params are identical.
func CompareKeysParams(key1 string, params1 []string, key2 string, params2 []string) bool {
	if key1 != key2 {
		return false
	}

	if len(params1) != len(params2) {
		return false
	}

	for i := range params1 {
		if params1[i] != params2[i] {
			return false
		}
	}

	return true
}

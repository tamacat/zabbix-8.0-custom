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
	"fmt"
	"strconv"
	"time"

	"golang.zabbix.com/sdk/plugin"
)

const StateNotSupported = 1

func ValueToString(u interface{}) *string {
	var s string

	switch v := u.(type) {
	case string:
		s = v
	case *string:
		return v
	case int:
		s = strconv.FormatInt(int64(v), 10)
	case int8:
		s = strconv.FormatInt(int64(v), 10)
	case int16:
		s = strconv.FormatInt(int64(v), 10)
	case int32:
		s = strconv.FormatInt(int64(v), 10)
	case int64:
		s = strconv.FormatInt(v, 10)
	case uint:
		s = strconv.FormatUint(uint64(v), 10)
	case uint8:
		s = strconv.FormatUint(uint64(v), 10)
	case uint16:
		s = strconv.FormatUint(uint64(v), 10)
	case uint32:
		s = strconv.FormatUint(uint64(v), 10)
	case uint64:
		s = strconv.FormatUint(v, 10)
	case float32:
		s = strconv.FormatFloat(float64(v), 'f', 6, 64)
	case float64:
		s = strconv.FormatFloat(v, 'f', 6, 64)
	default:
		// note that this conversion is slow and it's better to return known value type
		s = fmt.Sprintf("%v", u)
	}

	return &s
}

func ValueToResult(itemid uint64, ts time.Time, u interface{}) (result *plugin.Result) {
	var value *string
	switch v := u.(type) {
	case *plugin.Result:
		return v
	case plugin.Result:
		return &v
	case nil:
		return &plugin.Result{Itemid: itemid, Value: nil, Ts: ts}
	default:
		value = ValueToString(u)
	}

	return &plugin.Result{Itemid: itemid, Value: value, Ts: ts}
}

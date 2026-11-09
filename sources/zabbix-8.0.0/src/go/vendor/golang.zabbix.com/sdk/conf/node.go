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

// Package conf provides .conf file loading and unmarshalling
package conf

import (
	"bytes"
	"fmt"

	"golang.zabbix.com/sdk/errs"
)

var errNotfound = errs.New("no value found")

// Node structure is used to store parsed conf file parameters or parameter components.
type Node struct {
	Name  string
	Nodes []any
	Line  int

	used        bool
	parent      *Node
	level       int
	includeFail bool
}

// Value holds the value and line of the node.
type Value struct {
	Value []byte
	Line  int
}

// get returns child node by name.
func (n *Node) get(name string) *Node {
	for _, v := range n.Nodes {
		if child, ok := v.(*Node); ok && child.Name == name {
			return child
		}
	}

	return nil
}

// add appends new child node.
func (n *Node) add(name, value []byte, lineNum int) {
	var (
		node *Node
		key  string
	)

	split := bytes.IndexByte(name, '.')
	if split == -1 {
		key = string(name)
	} else {
		key = string(name[:split])
	}

	node = n.get(key)
	if node == nil {
		node = &Node{
			Name:   key,
			used:   false,
			Nodes:  make([]any, 0),
			parent: n,
			Line:   lineNum,
		}

		n.Nodes = append(n.Nodes, node)
	}

	if split != -1 {
		node.add(name[split+1:], value, lineNum)
	} else {
		node.Nodes = append(node.Nodes, &Value{Value: value, Line: lineNum})
	}
}

// checkUsage checks if all conf nodes were recognized.
// This is done by recursively checking 'used' flag for all nodes.
func (n *Node) checkUsage() error {
	for _, v := range n.Nodes {
		child, ok := v.(*Node)
		if !ok {
			continue
		}

		if !child.used {
			return newError(child, "unknown parameter")
		}

		err := child.checkUsage()
		if err != nil {
			return err
		}
	}

	return nil
}

// markUsed marks node and its children as used.
func (n *Node) markUsed(used bool) {
	n.used = used
	for _, v := range n.Nodes {
		if child, ok := v.(*Node); ok {
			child.markUsed(used)
		}
	}
}

// getValue returns node value or meta data default value or nil if
// metadata 'optional' tag is set. Otherwise error is returned.
func getValue(n *Node, meta *Meta) (*string, error) {
	var value *string

	if n != nil {
		var tmp string

		for _, v := range n.Nodes {
			val, ok := v.(*Value)
			if ok {
				tmp = string(val.Value)
			}

			value = &tmp
		}
	}

	if value != nil {
		return value, nil
	}

	if meta == nil {
		return nil, errNotfound
	}

	switch {
	case meta.defaultValue != nil:
		return meta.defaultValue, nil
	case meta.optional:
		return nil, nil //nolint:nilnil // expected output and makes reading of the returns easier.
	default:
		return nil, errs.Errorf("cannot find mandatory parameter %s", meta.name)
	}
}

// newError creates error based on the specified node. The error message will
// have full node name (parameter name up to the node, including it) and the line
// number where parameter was defined.
func newError(n *Node, format string, a ...any) error {
	if n == nil {
		return errs.Errorf(format, a...)
	}

	var name string

	for parent := n; parent.parent != nil; parent = parent.parent {
		if name == "" {
			name = parent.Name
		} else {
			name = parent.Name + "." + name
		}
	}

	desc := fmt.Sprintf(format, a...)

	return errs.Errorf("invalid parameter %s at line %d: %s", name, n.Line, desc)
}

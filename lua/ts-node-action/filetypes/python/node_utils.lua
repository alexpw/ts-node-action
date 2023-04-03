local actions = require("ts-node-action.actions")
local helpers = require("ts-node-action.helpers")

-- WARN: Functions defined here should be treated as private/internal.
-- This is like an incubator and all are subject to change.

-- NOTE: All functions are for TSNode, so rather than prefixing every function
-- name with "node_", the module is named "node_utils".

local M = {}

---@param node TSNode
---@return string
M.text = function(node)
  if not node then return "" end

  local buf = vim.api.nvim_get_current_buf()
  if vim.treesitter.get_node_text then
    return vim.trim(vim.treesitter.get_node_text(node, buf))
  else
    -- TODO: Remove in 0.10
    return vim.trim(vim.treesitter.query.get_node_text(node, buf))
  end
end

---@param node TSNode
---@return table
M.lines = function(node)
  local text = M.text(node)
  if not text then
    return {}
  end
  if text:match("\n") then
    return vim.tbl_map(vim.trim, vim.split(text, "\n"))
  end
  return { text }
end

-- Lines between two nodes. Inclusive of start node. Does not include end node.
--
---@param node_start TSNode
---@param node_end TSNode
---@return table
M.lines_between = function(node_start, node_end)
  local start_row, start_col = node_start:start()
  local end_row, end_col     = node_end:start()
  local lines   = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
  lines[1]      = lines[1]:sub(start_col + 1)
  if start_row == end_row then
    end_col = end_col - start_col + 1
  end
  lines[#lines] = lines[#lines]:sub(1, end_col)
  return lines
end

---@param nodes TSNode[]
---@return table
M.concat = function(nodes)
  local lines = {}
  for _, node_lines in ipairs(nodes) do
    vim.list_extend(lines, M.lines(node_lines))
  end
  return lines
end

-- Recreating actions.toggle_multiline.collapse_child_nodes() here because
-- it is not exported.
--
---@param padding table
---@param uncollapsible table
---@return function @A function that takes a TSNode and returns a string
M.collapse_func = function(padding, uncollapsible)
  local collapse = actions.toggle_multiline(padding, uncollapsible)[1][1]

  return function(node)
    if not helpers.node_is_multiline(node) then
      return M.text(node)
    end
    return collapse(node)
  end
end

---@param node TSNode
---@return boolean
M.has_comments = function(node)
  for child in M.iter_named_children(node) do
    if child:type() == "comment" then
      return true
    else
      M.has_comments(child)
    end
  end
  return false
end

---@param node_type string|table
---@return function @A function that takes a TSNode and returns a boolean
M.accept_type = function(node_type)
  if type(node_type) == "string" then
    return function(node)
      return node:type() == node_type
    end
  else
    return function(node)
      return vim.tbl_contains(node_type, node:type())
    end
  end
end

M.accept_comment = M.accept_type("comment")

-- Like vim.tbl_filter, but for TSNodes.
--
---@param accept fun(node: TSNode): boolean @returns true for a valid node
---@param iter fun(): TSNode|nil @returns the next node
---@return TSNode[]
M.filter = function(accept, iter)
  local nodes = {}
  local node  = iter()
  while node do
    if accept(node) then
      table.insert(nodes, node)
    end
    node = iter()
  end
  return nodes
end

-- Returns the first node that matches the accept function.
--
---@param accept fun(node: TSNode): boolean @returns true for a valid node
---@param iter fun(): TSNode|nil @returns the next node
---@return TSNode|nil
M.find = function(accept, iter)
  local node = iter()
  while node do
    if accept(node) then
      return node
    end
    node = iter()
  end
end

-- Like filter, but stops at the first falsey value.
--
---@param accept fun(node: TSNode): boolean @returns true for a valid node
---@param iter fun(): TSNode|nil @returns the next node
---@return TSNode[]
M.takewhile = function(accept, iter)
  local nodes = {}
  local node  = iter()
  while node and accept(node) do
    table.insert(nodes, node)
    node = iter()
  end
  return nodes
end

M.iter_named_children = function(node)
  local iter = node:iter_children()
  return function()
    local child = iter()
    while child and not child:named() do
      child = iter()
    end
    return child
  end
end
M.iter_prev_named_sibling = function(node)
  local sibling = node:prev_named_sibling()
  return function()
    if sibling then
      local curr_sibling = sibling
      sibling = sibling:prev_named_sibling()
      return curr_sibling
    end
  end
end
M.iter_next_named_sibling = function(node)
  local sibling = node:next_named_sibling()
  return function()
    if sibling then
      local curr_sibling = sibling
      sibling = sibling:next_named_sibling()
      return curr_sibling
    end
  end
end
M.iter_parent = function(node)
  local parent = node:parent()
  return function()
    if parent then
      local curr_parent = parent
      parent = parent:parent()
      return curr_parent
    end
  end
end

-- Create a fake node to represent the replacement target. This is necessary
-- when the replacement spans multiple nodes without a suitable parent to serve
-- as a the target (eg, a top-level node's parent is the root and we are acting
-- on multiple children).
--
-- This is indistiguishable from a TSNode, other than type(target) == "table".
--
---@param node TSNode
---@param start_pos table
---@param end_pos table
---@return table
M.make_target = function(node, start_pos, end_pos)
  -- TSNode's are userdata, which can't be cloned/altered, so this proxy's calls
  -- to it and overrides the position methods.
  local target = {}
  for k, _ in pairs(getmetatable(node)) do
    target[k] = function(_, ...)
      return node[k](node, ...)
    end
  end
  function target:start() return unpack(start_pos) end
  function target:end_() return unpack(end_pos) end
  function target:range()
    return start_pos[1], start_pos[2], end_pos[1], end_pos[2]
  end

  return target
end

---@param node TSNode
M.trim_whitespace = function(node)
  local start_row, _, end_row, _ = node:range()
  vim.cmd("silent! keeppatterns " .. (start_row + 1) .. "," .. (end_row + 1) .. "s/\\s\\+$//g")
end

return M

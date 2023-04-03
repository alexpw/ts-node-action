local nu = require("ts-node-action.filetypes.python.node_utils");


local collection_types = {
  list         = {
    name       = "list",
    init       = { "[]", "list()" },
    tag_empty  = "[]",
    tag_open   = "[",
    tag_close  = "]",
    method_add = "append",
  },
  set          = {
    name       = "set",
    init       = { "set()" },
    tag_empty  = "set()",
    tag_open   = "{",
    tag_close  = "}",
    method_add = "add",
  },
  dictionary   = {
    name       = "dict",
    init       = { "{}", "dict()" },
    tag_empty  = "{}",
    tag_open   = "{",
    tag_close  = "}",
    method_add = "",
  },
}
collection_types.dict = collection_types.dictionary

local function list_pop(tbl, default)
  if tbl then
    local last = tbl[#tbl]
    tbl[#tbl] = nil
    return last
  end
  return default
end

local function append_lines(replacement, lines, indent, prepend, append)
  local line_cnt = #lines
  for i, line in ipairs(lines) do
    if i == 1 then
      line = (prepend or "") .. line
    elseif i == 2 and line_cnt > 2 then
      indent = indent .. "    "
    end
    if i == line_cnt then
      line = line .. (append or "")
      if line_cnt > 2 then
        indent = indent:sub(1, -5)
      end
    end
    table.insert(replacement, indent .. line)
  end
  return indent
end

local function destructure_comment(comment)
  return {
    type = "comment",
    text = nu.text(comment),
    inline = comment:start() == comment:prev_named_sibling():end_()
  }
end

local function destructure_comprehension(comprehension)
  local body
  local clauses_and_comments  = {}
  local body_comments = {}

  for child in comprehension:iter_children() do
    if child:named() then
      local child_type = child:type()
      if not body then
        if child_type == "comment" then
          table.insert(body_comments, child)
        else
          body = child
        end
      else
        table.insert(clauses_and_comments, child)
      end
    end
  end

  return {
    node = comprehension,
    body = body,
    clauses_and_comments = clauses_and_comments,
    body_comments        = body_comments,
  }
end

---@param for_in_clause TSNode
---@return table|nil, table|nil
local function expand_comprehension(for_in_clause)

  local comprehension = for_in_clause:parent()
  local parent        = comprehension:parent()
  local comp_type     = vim.split(comprehension:type(), "_")[1]
  local coll_cfg      = collection_types[comp_type]

  if not coll_cfg or parent:type() == "call" then
    if comp_type ~= "list" and comp_type ~= "generator" then
      return
    end
    coll_cfg = collection_types[nu.text(parent:named_child(0))]
    if not coll_cfg then
      return
    end
    parent = parent:parent()
  end

  local identifiers = {}
  if parent:type() == "assignment" then
    while parent:type() == "assignment" do
      table.insert(identifiers, 1, nu.text(parent:named_child(0)))
      parent = parent:parent()
    end
  elseif parent:type() == "return_statement" then
    table.insert(identifiers, 1, "result")
  else
    return
  end

  local stmt = destructure_comprehension(comprehension)
  if not stmt then
    return
  end

  local replacement = {
    table.concat(identifiers, " = ") .. " = " .. coll_cfg.init[1],
  }

  local _, start_col = parent:start()
  local start_indent = string.rep(" ", start_col)
  local indent = start_indent

  for _, clause_or_comment in ipairs(stmt.clauses_and_comments) do
    if clause_or_comment:type() == "comment" then
      local prev_row = clause_or_comment:prev_named_sibling():end_()
      if prev_row == clause_or_comment:start() then
        local prepend = list_pop(replacement)
        table.insert(replacement, prepend .. " " .. nu.text(clause_or_comment))
      else
        table.insert(replacement, indent .. nu.text(clause_or_comment))
      end
    else
      local lines = nu.lines(clause_or_comment)
      append_lines(replacement, lines, indent, "", ":")
      indent = indent .. "    "
    end
  end

  if stmt.body_comments then
    for _, comment in ipairs(stmt.body_comments) do
      table.insert(replacement, indent .. nu.text(comment))
    end
  end

  if coll_cfg.name == "dict" then
    local keys   = nu.lines(stmt.body:named_child(0))
    local values = nu.lines(stmt.body:named_child(1))
    for _, identifier in ipairs(identifiers) do
      local prepend = identifier .. "["
      append_lines(replacement, keys, indent, prepend, "] = ")
      prepend = list_pop(replacement)
      append_lines(replacement, values, indent, prepend)
    end
  else
    local values = nu.lines(stmt.body)
    for _, identifier in ipairs(identifiers) do
      local prepend = identifier .. "." .. coll_cfg.method_add .. "("
      append_lines(replacement, values, indent, prepend, ")")
    end
  end

  if parent:type() == "return_statement" then
    table.insert(replacement, start_indent .. "return " .. identifiers[1])
  end

  return replacement, {
    cursor = { row = 1, col = 0 },
    format = true,
    target = parent,
  }
end


local function last_named_child(node)
  local cnt = node:named_child_count()
  if cnt == 0 then return end
  return node:named_child(cnt - 1)
end

local function subscript_key(subscript)
  local start = subscript:child(1)
  local stop
  for i = 2, subscript:child_count() - 1 do
    stop = subscript:child(i)
    if nu.text(stop) == "=" then
      break
    end
  end
  if not stop then
    return
  end
  local lines = nu.lines_between(start, stop)
  if lines[1]:sub(1, 1) == "[" then
    lines[1] = lines[1]:sub(2)
  end
  if lines[#lines]:sub(-1) == "]" then
    lines[#lines] = lines[#lines]:sub(1, -2)
  end
  return lines
end

local function destructure_for_if_body_block(block, identifiers)

  local body_stmts = {}
  local comments = {}
  local seen_identifiers = {}
  for expr_stmt in block:iter_children() do
    local expr_type = expr_stmt:type()
    if expr_type == "comment" then
      table.insert(comments, nu.text(expr_stmt))
    elseif expr_type == "expression_statement" then
      local expr = expr_stmt:child()
      if expr:type() == "call" then
        local fn         = expr:named_child(0)
        local identifier = nu.text(fn:named_child(0))
        local method     = nu.text(fn:named_child(1))
        if method ~= "append" and method ~= "add" then
          return
        end
        if not vim.tbl_contains(identifiers, identifier) then
          return
        end
        if seen_identifiers[identifier] then
          return
        end
        seen_identifiers[identifier] = true

        local lines = nu.lines(expr:named_child(1))
        local text  = table.concat(lines, " ")
        -- trim the parentheses
        lines[1]      = lines[1]:sub(2)
        lines[#lines] = lines[#lines]:sub(1, -2)
        if #body_stmts > 0 and body_stmts[1].text ~= text then
          return
        end
        table.insert(body_stmts, {
          type       = "call",
          expr       = expr,
          identifier = identifier,
          method     = method,
          lines      = lines,
          text       = text,
        })

      elseif expr:type() == "assignment" then
        local assignment = expr
        local subscript  = assignment:named_child(0)
        local seen_keys  = {}
        while subscript do
          if subscript:type() ~= "subscript" then
            break
          end

          local identifier = nu.text(subscript:named_child(0))
          if not vim.tbl_contains(identifiers, identifier) then
            return
          end
          if seen_identifiers[identifier] then
            return
          end
          seen_identifiers[identifier] = true

          local key = subscript_key(subscript)
          if not key then
            return
          end
          table.insert(seen_keys, table.concat(key, ""))

          local value = assignment:named_child(1)
          if value:type() == "assignment" then
            assignment = value
            subscript  = assignment:named_child(0)
          else
            local lines = nu.lines(value)
            local text  = table.concat(lines, " ")
            if #body_stmts > 0 and body_stmts[1].text ~= text then
              return
            end
            table.insert(body_stmts, {
              type  = "assignment",
              expr  = expr,
              identifier = identifier,
              key   = key,
              lines = lines,
              text  = text,
            })
            if #seen_keys > 1 then
              for i = 1, #seen_keys - 1 do
                if seen_keys[i] ~= seen_keys[i + 1] then
                  return
                end
              end
            end
            subscript = nil
            break
          end
        end
      else
        return
      end
    end
  end

  return body_stmts, comments
end

---@param node_rhs TSNode
---@return table|nil
local function get_assignment_collection_info(node_rhs)
  local coll_type = collection_types[node_rhs:type()]
  if coll_type then
    return coll_type
  elseif node_rhs:type() == "call" then
    local fn_name = nu.text(node_rhs:named_child(0))
    coll_type = collection_types[fn_name]
    if coll_type then
      local argument_list = nu.text(node_rhs:named_child(1)):gsub("%s+", "")
      if argument_list ~= "()" then
        return
      end
      return coll_type
    end
  end
end

---@param for_statement TSNode
---@return table|nil
local function destructure_for_comprehension(for_statement)

  local expr_stmt = for_statement:prev_named_sibling()
  if not expr_stmt or expr_stmt:type() ~= "expression_statement" then
    return
  end

  local identifiers = {}
  local assignment = expr_stmt:child()
  while assignment and assignment:type() == "assignment" do
    table.insert(identifiers, nu.text(assignment:named_child(0)))
    assignment = assignment:named_child(1)
  end
  if #identifiers == 0 then
    return
  end

  local for_if_stmts = {}
  local for_if_stmt  = for_statement
  while for_if_stmt do

    if for_if_stmt:type() == "for_statement" then
      table.insert(for_if_stmts, {
        type  = "for_statement",
        node  = for_if_stmt,
        left  = nu.lines(for_if_stmt:named_child(0)),
        right = nu.lines(for_if_stmt:named_child(1)),
      })
    elseif for_if_stmt:type() == "if_statement" then
      table.insert(for_if_stmts, {
        type      = "if_statement",
        node      = for_if_stmt,
        condition = nu.lines(for_if_stmt:named_child(0)),
      })
    else
      break
    end

    vim.list_extend(
      for_if_stmts,
      vim.tbl_map(
        destructure_comment,
        nu.filter(nu.accept_comment, nu.iter_named_children(for_if_stmt))))

    for_if_stmt = last_named_child(for_if_stmt):child()
  end

  local block = for_if_stmt:parent()
  local body_stmts, body_comments = destructure_for_if_body_block(block, identifiers)
  if not body_stmts then
    return
  end

  return {
    type          = "for_statement",
    node          = for_statement,
    expr_stmt     = expr_stmt,
    identifiers   = identifiers,
    collection    = get_assignment_collection_info(assignment),
    for_if_stmts  = for_if_stmts,
    body_stmts    = body_stmts,
    body_comments = body_comments
  }
end

-- there must be:
-- 1. an assignment, eg, list1 = [], defined immediately before the loop.
-- 2. only 1 (non-for/non-if) statement in the body, and it must be:
--   - the deepest child
--   - an append(), add(), or key=value acting on the list1 identifier.
--
---@param for_statement TSNode
---@return table|nil, table|nil
local function collapse_for_comprehension(for_statement)

  local stmt = destructure_for_comprehension(for_statement)
  vim.print(stmt)
  if not stmt then
    return
  end

  local _, start_col = for_statement:start()
  local indent = string.rep(" ", start_col)

  local assignment = table.concat(stmt.identifiers, " = ") .. " = "
    .. stmt.collection.tag_open

  local body = stmt.body_stmts[1]

  local is_multiline = nu.has_comments(for_statement)
  if is_multiline == false then
    is_multiline = #body.lines > 1
    if stmt.collection.name == "dict" then
      if #body.key > 1 then
        is_multiline = true
      end
    end
    for _, for_if_stmt in ipairs(stmt.for_if_stmts) do
      if for_if_stmt.type == "for_statement" then
        if #for_if_stmt.left > 1 or #for_if_stmt.right > 1 then
          is_multiline = true
        end
      elseif for_if_stmt.type == "if_statement" then
        if #for_if_stmt.condition > 1 then
          is_multiline = true
        end
      end
    end
  end

  local line_length = 0
  if is_multiline == false then
    line_length = #assignment + #body.lines[1]
    if stmt.collection.name == "dict" then
      line_length = line_length + #body.key[1] + 2
    end
    for _, for_if_stmt in ipairs(stmt.for_if_stmts) do
      if for_if_stmt.type == "for_statement" then
        line_length = line_length + #for_if_stmt.left[1] + #for_if_stmt.right[1]
      elseif for_if_stmt.type == "if_statement" then
        line_length = line_length + #for_if_stmt.condition[1]
      end
    end
    if line_length > 80 then
      is_multiline = true
    end
  end

  local replacement = {}
  if is_multiline then
    indent = indent .. "    "
    if #stmt.body_comments > 0 then
      append_lines(replacement, stmt.body_comments, indent, assignment)
    else
      table.insert(replacement, assignment)
    end
  end

  if stmt.collection.name == "dict" then
    local prepend = (is_multiline and "" or assignment)
    append_lines(replacement, body.key, indent, prepend, ": ")
    prepend = list_pop(replacement)
    append_lines(replacement, body.lines, indent, prepend)
  else
    local prepend = is_multiline and "" or assignment
    append_lines(replacement, body.lines, indent, prepend)
  end

  local ix_first_for = 0
  for _, for_if_stmt in ipairs(stmt.for_if_stmts) do
    if for_if_stmt.type == "comment" then
      local prepend = for_if_stmt.inline and list_pop(replacement) .. " "
      table.insert(replacement, (prepend or "") .. for_if_stmt.text)
    elseif for_if_stmt.type == "for_statement" then
      if ix_first_for == 0 then
        ix_first_for = #replacement + 1
      end
      append_lines(replacement, for_if_stmt.left, indent, "for ", " in ")
      local prepend = list_pop(replacement)
      append_lines(replacement, for_if_stmt.right, indent, prepend)
    elseif for_if_stmt.type == "if_statement" then
      append_lines(replacement, for_if_stmt.condition, indent, "if ")
    end
  end

  if is_multiline then
    table.insert(replacement, stmt.collection.tag_close)
  else
    local append = stmt.collection.tag_close
    replacement[#replacement] = replacement[#replacement] .. append
  end

  local target = nu.make_target(
    for_statement,
    { stmt.expr_stmt:start() },
    { for_statement:end_() }
  )

  local cursor
  if is_multiline == false then
    local collapsed = table.concat(replacement, " ")
    if #collapsed <= 80 then
      cursor = {
        row = 0,
        col = collapsed:find("for") - 1
      }
      replacement = { collapsed }
    end
  end

  local callback
  if #replacement > 1 then
    callback = function()
      -- position cursor on the first for statement
      local start = { target:start() }
      local row   = start[1] + ix_first_for - 1
      local lines = vim.api.nvim_buf_get_lines(0, row, row + 1, false)
      local col   = lines[1]:find("for") - 1
      vim.api.nvim_win_set_cursor(
        vim.api.nvim_get_current_win(),
        { row + 1, col }
      )
    end
  end

  return replacement, {
    format   = true,
    target   = target,
    cursor   = cursor,
    callback = callback
  }
end

return {
  expand_comprehension = expand_comprehension,
  collapse_for_statement = collapse_for_comprehension
}

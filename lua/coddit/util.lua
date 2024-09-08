local M = {}

function M.is_visual_mode()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == " "
end

function M.switch_to_buf_win(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end

function M.get_sel_range()
  local is_visual_mode = M.is_visual_mode()
  local end_line = vim.fn.getpos(".")[2]

  local start_line
  if is_visual_mode then
    start_line = vim.fn.getpos("v")[2]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
  else
    start_line = 1
  end

  return start_line, end_line
end

---@param bufnr integer
---@param filetype string
function M.duplicate_buffer(bufnr, filetype)
  if bufnr == -1 then
    vim.notify("Buffer unloaded", vim.log.levels.ERROR)
    return nil
  end

  local timestamp = os.time()
  local tmp_filepath = string.format("/tmp/nvim_temp_%d", timestamp)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local file = io.open(tmp_filepath, "w")
  if file then
    for _, line in ipairs(lines) do
      file:write(line .. "\n")
    end
    file:close()
  end

  vim.api.nvim_command("edit " .. tmp_filepath)

  local tmp_bufnr = vim.fn.bufnr(tmp_filepath)
  vim.api.nvim_set_option_value("filetype", filetype, { buf = tmp_bufnr })

  return tmp_bufnr
end

---@param default boolean
---@param arr boolean[]
---@return boolean
function M.get_first_boolean(default, arr)
  for i = 1, #arr do
    if arr[i] ~= nil then
      return arr[i]
    end
  end
  return default
end

---@param s string
function M.trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

---@param str string
---@param query string
---@return integer
function M.find_last_line_match(str, query)
  local last_line = -1
  for i, line in ipairs(vim.split(str, "\n")) do
    if M.trim(line) == query then
      last_line = i
    end
  end
  return last_line
end

---@param input_string string
---@param start? integer
---@return string
function M.add_line_numbers(input_string, start)
  if not start then
    start = 1
  end
  local lines = vim.split(input_string, "\n")
  local numbered_lines = {}
  for i, line in ipairs(lines) do
    table.insert(numbered_lines, string.format("<%d> %s", i + start - 1, line))
  end
  return table.concat(numbered_lines, "\n")
end

function M.decode_response(response)
  local result = {}
  local lines = vim.split(response, "\n")
  local current_update = {}
  local in_code_block = false

  for _, line in ipairs(lines) do
    if line:match("^<ct_lines_to_update>$") then
      current_update = {}
    elseif line:match("^</ct_lines_to_update>$") then
      -- Do nothing, just skip this line
    elseif line:match("^(%d+)-(%d+)$") then
      local start_line, end_line = line:match("^(%d+)-(%d+)$")
      current_update.start_line = tonumber(start_line)
      current_update.end_line = tonumber(end_line)
    elseif line:match("^<ct_updated_code>$") then
      current_update.code = ""
      in_code_block = true
    elseif line:match("^</ct_updated_code>$") then
      in_code_block = false
      table.insert(result, current_update)
    else
      if in_code_block then
        current_update.code = current_update.code .. (current_update.code ~= "" and "\n" or "") .. line
      end
    end
  end

  if in_code_block and current_update.start_line and current_update.end_line then
    table.insert(result, current_update)
  end

  table.sort(result, function(a, b)
    return a.start_line < b.start_line
  end)

  return result
end

function M.apply_patch(updates, source_bufnr, dest_bufnr)
  local source_lines = vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)

  for i = #updates, 1, -1 do
    local update = updates[i]
    local start_line = update.start_line - 1
    local end_line = update.end_line - 1
    local new_lines = vim.split(update.code, "\n")

    for _ = start_line, end_line do
      table.remove(source_lines, start_line + 1)
    end

    for j = #new_lines, 1, -1 do
      table.insert(source_lines, start_line + 1, new_lines[j])
    end
  end

  vim.api.nvim_buf_set_lines(dest_bufnr, 0, -1, false, source_lines)
end

function M.process_and_apply_patch(response, source_bufnr, dest_bufnr)
  local updates = M.decode_response(response)
  M.apply_patch(updates, source_bufnr, dest_bufnr)
end

---@param response string
---@return string[]
function M.get_lines_to_append(response)
  local lines = vim.split(response, "\n")
  if M.trim(lines[1]) ~= "<ct_updated_code>" then
    return {}
  end
  if M.trim(lines[#lines]) ~= "</ct_updated_code>" then
    return vim.list_slice(lines, 2, #lines)
  else
    return vim.list_slice(lines, 2, #lines - 1)
  end
end

return M

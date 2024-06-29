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

return M

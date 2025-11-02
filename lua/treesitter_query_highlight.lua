local M = {}

local ns_id = vim.api.nvim_create_namespace('treesitter_query_highlight')
local matches = {}
local current_match = 0

function M.clear_highlights()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  matches = {}
  current_match = 0
end

function M.highlight_query(query_string, on_error)
  M.clear_highlights()
  
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr)
  
  if not parser then
    vim.notify("No treesitter parser available for this buffer", vim.log.levels.ERROR)
    return false
  end
  
  local lang = parser:lang()
  local tree = parser:parse()[1]
  local root = tree:root()
  
  local ok, query = pcall(vim.treesitter.query.parse, lang, query_string)
  if not ok then
    local error_msg = tostring(query)
    if on_error then
      on_error(error_msg)
    else
      vim.notify("Invalid treesitter query: " .. error_msg, vim.log.levels.ERROR)
    end
    return false
  end
  
  matches = {}
  for _, node in query:iter_captures(root, bufnr, 0, -1) do
    local start_row, start_col, end_row, end_col = node:range()
    table.insert(matches, { start_row, start_col, end_row, end_col })
    
    if start_row == end_row then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Search', start_row, start_col, end_col)
    else
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Search', start_row, start_col, -1)
      for row = start_row + 1, end_row - 1 do
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Search', row, 0, -1)
      end
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Search', end_row, 0, end_col)
    end
  end
  
  current_match = 0
  vim.notify(string.format("Highlighted %d matches", #matches), vim.log.levels.INFO)
  return true
end

function M.prompt_query()
  vim.ui.input({ prompt = 'Treesitter Query: ' }, function(input)
    if input and input ~= '' then
      M.highlight_query(input)
    end
  end)
end

function M.prompt_natural_language()
  local coddit = require('coddit')
  
  vim.ui.input({ prompt = 'Describe what to highlight: ' }, function(input)
    if not input or input == '' then
      return
    end
    
    local bufnr = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufnr)
    if not parser then
      vim.notify("No treesitter parser available for this buffer", vim.log.levels.ERROR)
      return
    end
    local lang = parser:lang()
    
    local prompt_file = vim.fn.stdpath('data') .. '/lazy/coddit.nvim/lua/treesitter-query-agent-prompt.md'
    local file = io.open(prompt_file, 'r')
    local system_prompt = file and file:read('*all') or ''
    if file then file:close() end
    
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines > 200 then
      lines = vim.list_slice(lines, 1, 200)
    end
    local code_sample = table.concat(lines, '\n')
    
    local model_opts = coddit.opts.models[coddit.opts.selected_model]
    local api_opts = coddit.opts.api_types[model_opts.api_type]
    
    local endpoint = model_opts.endpoint or api_opts.endpoint
    local get_api_payload = model_opts.get_api_payload or api_opts.get_api_payload
    local get_headers = model_opts.get_headers or api_opts.get_headers
    local extract_assistant_response = model_opts.extract_assistant_response or api_opts.extract_assistant_response
    
    local function attempt_query(attempt, previous_error)
      local user_prompt
      if previous_error then
        user_prompt = string.format(
          "Language: %s\nTask: %s\n\nPrevious attempt failed with error:\n%s\n\nPlease fix the query.\n\nCode context:\n```\n%s\n```",
          lang, input, previous_error, code_sample
        )
      else
        user_prompt = string.format("Language: %s\nTask: %s\n\nCode context:\n```\n%s\n```", lang, input, code_sample)
      end
      
      if attempt > 1 then
        vim.notify(string.format("Retry attempt %d/3...", attempt - 1), vim.log.levels.WARN)
      else
        vim.notify("Generating query...", vim.log.levels.INFO)
      end
      
      local temp_model_opts = vim.tbl_extend('force', model_opts, { 
        system_prompt = system_prompt,
        stream = false
      })
      local temp_opts = vim.tbl_extend('force', coddit.opts, { stream = false })
      local body = get_api_payload(user_prompt, temp_model_opts, api_opts, temp_opts)
      local headers = get_headers(model_opts, api_opts, temp_opts)
      
      require('plenary.curl').post(endpoint, {
        body = body,
        headers = headers,
        callback = function(response_http)
          vim.schedule(function()
            if response_http.status ~= 200 then
              vim.notify("API error: " .. vim.inspect(response_http), vim.log.levels.ERROR)
              return
            end
            
            local query_str = extract_assistant_response(response_http.body, model_opts, api_opts, temp_opts)
            if not query_str then
              vim.notify("Failed to extract query from response", vim.log.levels.ERROR)
              return
            end
            
            query_str = query_str:gsub('^%s*(.-)%s*$', '%1')
            query_str = query_str:gsub('^```.-\n', ''):gsub('\n```$', '')
            
            vim.notify("Running query: " .. query_str, vim.log.levels.INFO)
            
            local success = M.highlight_query(query_str, function(error_msg)
              if attempt < 3 then
                attempt_query(attempt + 1, error_msg)
              else
                vim.notify("Failed after 3 attempts. Last error: " .. error_msg, vim.log.levels.ERROR)
              end
            end)
            
            if success and #matches == 0 and attempt < 3 then
              vim.notify("Query returned 0 matches, retrying...", vim.log.levels.WARN)
              attempt_query(attempt + 1, "Query was valid but returned 0 matches. Try a different approach.")
            elseif not success and attempt >= 3 then
              vim.notify("Query generation failed after 3 attempts", vim.log.levels.ERROR)
            end
          end)
        end,
        error_callback = function(err)
          vim.schedule(function()
            vim.notify("Error calling API: " .. tostring(err), vim.log.levels.ERROR)
          end)
        end,
      })
    end
    
    attempt_query(1, nil)
  end)
end

function M.next_match()
  if #matches == 0 then
    vim.notify("No matches available", vim.log.levels.WARN)
    return
  end
  
  current_match = current_match % #matches + 1
  local match = matches[current_match]
  vim.api.nvim_win_set_cursor(0, { match[1] + 1, match[2] })
  vim.notify(string.format("Match %d/%d", current_match, #matches), vim.log.levels.INFO)
end

function M.prev_match()
  if #matches == 0 then
    vim.notify("No matches available", vim.log.levels.WARN)
    return
  end
  
  current_match = current_match - 1
  if current_match < 1 then current_match = #matches end
  local match = matches[current_match]
  vim.api.nvim_win_set_cursor(0, { match[1] + 1, match[2] })
  vim.notify(string.format("Match %d/%d", current_match, #matches), vim.log.levels.INFO)
end

function M.setup()
  vim.api.nvim_create_user_command('TSQueryHighlight', M.prompt_query, {})
  vim.api.nvim_create_user_command('TSQueryClear', M.clear_highlights, {})
  vim.api.nvim_create_user_command('TSQueryNext', M.next_match, {})
  vim.api.nvim_create_user_command('TSQueryPrev', M.prev_match, {})
  vim.api.nvim_create_user_command('TSQueryNL', M.prompt_natural_language, {})
  
  vim.keymap.set('n', '<leader>ait', M.prompt_natural_language, { desc = 'Treesitter query (natural language)' })
  vim.keymap.set('n', '<leader>aiT', M.clear_highlights, { desc = 'Clear treesitter query highlights' })
  vim.keymap.set('n', ']x', M.next_match, { desc = 'Next treesitter match' })
  vim.keymap.set('n', '[x', M.prev_match, { desc = 'Previous treesitter match' })
end

return M

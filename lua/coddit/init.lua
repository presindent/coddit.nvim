local curl = require("plenary.curl")
local util = require("coddit.util")

local M = {}

M.dup_bufnr = -1
M.main_bufnr = -1

---@class ModelOpts
---@field endpoint? string
---@field model? string
---@field api_type? string
---@field api_key? string
---@field system_prompt? string
---@field stream? boolean
---@field max_tokens? number
---@field get_headers? fun(model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): table<string, string>
---@field get_api_payload? fun(prompt: string, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string
---@field extract_assistant_response? fun(response: string, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string|nil
---@field extract_text_delta? fun(response: string, state?: { event: string }, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string|nil

---@class ApiOpts
---@field endpoint string
---@field api_key? string
---@field system_prompt? string
---@field stream? boolean
---@field max_tokens? number
---@field get_headers? fun(model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): table<string, string>
---@field get_api_payload fun(prompt: string, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string
---@field extract_assistant_response fun(response: string, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string|nil
---@field extract_text_delta? fun(response: string, state?: { event: string }, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string|nil

---@class Opts
---@field api_types? table<string, ApiOpts>
---@field models? table<string, ModelOpts>
---@field selected_model? string
---@field max_tokens? number
---@field system_prompt? string
---@field stream? boolean
---@field show_diff? boolean

---@alias PromptMode "append" | "edit"

---@type Opts
M.opts = {
  api_types = {
    ["anthropic"] = {
      endpoint = "https://api.anthropic.com/v1/messages",
      get_headers = function(model_opts, api_opts)
        local api_key = model_opts.api_key or api_opts.api_key or os.getenv("ANTHROPIC_API_KEY") or ""
        return {
          ["Content-Type"] = "application/json",
          ["X-API-Key"] = api_key,
          ["anthropic-version"] = "2023-06-01",
        }
      end,
      get_api_payload = function(prompt, model_opts, api_opts)
        local system_prompt = model_opts.system_prompt or api_opts.system_prompt or M.opts.system_prompt
        local max_tokens = model_opts.max_tokens or api_opts.max_tokens or M.opts.max_tokens
        local stream = util.get_first_boolean(true, { model_opts.stream, api_opts.stream, M.opts.stream })

        return vim.fn.json_encode({
          system = system_prompt,
          messages = { { role = "user", content = prompt } },
          model = model_opts.model,
          stream = stream,
          max_tokens = max_tokens,
        })
      end,
      extract_assistant_response = function(response)
        local decoded = vim.fn.json_decode(response)
        if decoded and decoded.content and #decoded.content > 0 then
          return decoded.content[1].text
        end
        return nil
      end,
      extract_text_delta = function(response, state)
        if not response then
          return
        end
        local chunk_body = response:match("^data: (.+)$")
        if chunk_body and state.event == "content_block_delta" then
          local ok, chunk_json = pcall(vim.fn.json_decode, chunk_body)
          if ok and chunk_json and chunk_json.delta and chunk_json.delta.text then
            return chunk_json.delta.text
          else
            util.notify("Error decoding chunk JSON", vim.log.levels.ERROR)
          end
        else
          state.event = response:match("^event: (.+)$")
        end
      end,
    },
    ["openai"] = {
      endpoint = "https://api.openai.com/v1/chat/completions",
      get_headers = function(model_opts, api_opts)
        local api_key = model_opts.api_key or api_opts.api_key or os.getenv("OPENAI_API_KEY") or ""
        return {
          ["Content-Type"] = "application/json",
          ["Authorization"] = "Bearer " .. api_key,
        }
      end,
      get_api_payload = function(prompt, model_opts, api_opts)
        local system_prompt = model_opts.system_prompt or api_opts.system_prompt or M.opts.system_prompt
        local max_tokens = model_opts.max_tokens or api_opts.max_tokens or M.opts.max_tokens
        local stream = util.get_first_boolean(true, { model_opts.stream, api_opts.stream, M.opts.stream })

        return vim.fn.json_encode({
          messages = {
            { role = "system", content = system_prompt },
            { role = "user", content = prompt },
          },
          model = model_opts.model,
          stream = stream,
          max_tokens = max_tokens,
        })
      end,
      extract_assistant_response = function(response)
        local decoded = vim.fn.json_decode(response)
        if decoded and decoded.choices and #decoded.choices > 0 then
          return decoded.choices[1].message.content
        end
        return nil
      end,
      extract_text_delta = function(response)
        if not response then
          return
        end
        local chunk_body = response:match("^data: (.+)$")
        if chunk_body then
          if chunk_body == "[DONE]" then
            return
          end
          local ok, chunk_json = pcall(vim.fn.json_decode, chunk_body)
          if ok and chunk_json.choices and chunk_json.choices[1] and chunk_json.choices[1].delta then
            local delta = chunk_json.choices[1].delta
            if delta.content then
              return delta.content
            end
          else
            util.notify("Error decoding chunk JSON", vim.log.levels.ERROR)
          end
        end
      end,
    },
    ["openai-o1"] = {
      endpoint = "https://api.openai.com/v1/chat/completions",
      get_headers = function(model_opts, api_opts)
        local api_key = model_opts.api_key or api_opts.api_key or os.getenv("OPENAI_API_KEY") or ""
        return {
          ["Content-Type"] = "application/json",
          ["Authorization"] = "Bearer " .. api_key,
        }
      end,
      get_api_payload = function(prompt, model_opts, api_opts)
        local system_prompt = model_opts.system_prompt or api_opts.system_prompt or M.opts.system_prompt
        local max_tokens = model_opts.max_tokens or api_opts.max_tokens or M.opts.max_tokens
        local stream = util.get_first_boolean(true, { model_opts.stream, api_opts.stream, M.opts.stream })

        return vim.fn.json_encode({
          messages = {
            { role = "user", content = system_prompt .. "\n\n" .. prompt }, -- O1 models don't support system prompts
          },
          model = model_opts.model,
          stream = stream,
          max_completion_tokens = max_tokens, -- O1 models take max_completion_tokens instead of max_tokens
        })
      end,
      extract_assistant_response = function(response)
        local decoded = vim.fn.json_decode(response)
        if decoded and decoded.choices and #decoded.choices > 0 then
          return decoded.choices[1].message.content
        end
        return nil
      end,
      extract_text_delta = function(response)
        if not response then
          return
        end
        local chunk_body = response:match("^data: (.+)$")
        if chunk_body then
          if chunk_body == "[DONE]" then
            return
          end
          local ok, chunk_json = pcall(vim.fn.json_decode, chunk_body)
          if ok and chunk_json.choices and chunk_json.choices[1] and chunk_json.choices[1].delta then
            local delta = chunk_json.choices[1].delta
            if delta.content then
              return delta.content
            end
          else
            util.notify("Error decoding chunk JSON", vim.log.levels.ERROR)
          end
        end
      end,
    },
  },
  models = {
    ["gemini-2.5-flash"] = {
      model = "gemini-2.5-flash",
      api_type = "openai",
      api_key = os.getenv("GEMINI_API_KEY"),
      endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    },
    ["gemini-flash-latest"] = {
      model = "gemini-flash-latest",
      api_type = "openai",
      api_key = os.getenv("GEMINI_API_KEY"),
      endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    },
    ["gemini-flash-lite-latest"] = {
      model = "gemini-flash-lite-latest",
      api_type = "openai",
      api_key = os.getenv("GEMINI_API_KEY"),
      endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    },
    ["gemini-2.5-pro"] = {
      model = "gemini-2.5-pro",
      api_type = "openai",
      api_key = os.getenv("GEMINI_API_KEY"),
      endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      max_tokens = 65536,
    },
    ["sonnet"] = {
      model = "claude-sonnet-4-5",
      api_type = "anthropic",
    },
    ["haiku"] = {
      model = "claude-haiku-4-5",
      api_type = "anthropic",
    },
    ["gpt-5"] = {
      model = "gpt-5",
      api_type = "openai",
    },
    ["gpt-5-mini"] = {
      model = "gpt-5-mini",
      api_type = "openai",
    },
    ["gpt-5-nano"] = {
      model = "gpt-5-nano",
      api_type = "openai",
    },
    ["deepseek-v3.2-exp"] = {
      model = "deepseek-chat",
      api_type = "openai",
      api_key = os.getenv("DEEPSEEK_API_KEY"),
      endpoint = "https://api.deepseek.com/chat/completions",
      max_tokens = 8192,
    },
    ["deepseek-reasoner"] = {
      model = "deepseek-reasoner",
      api_type = "openai",
      api_key = os.getenv("DEEPSEEK_API_KEY"),
      endpoint = "https://api.deepseek.com/chat/completions",
      max_tokens = 8192,
    },
  },
  selected_model = "haiku",
  max_tokens = 32768,
  system_prompt = [[
You are an AI coding assistant that updates code directly in the editor. Your task is to modify or append code based on the given instructions. You will receive input in the following format:

<ct_language>[programming language]</ct_language>
<ct_snippet>[code snippet]</ct_snippet>
<ct_task>[append or edit]</ct_task>

For 'edit' tasks:
1. The snippet will include line numbers.
2. Provide your changes using the following format, with XML tags on separate lines:
   <ct_lines_to_update>
   [line range to edit, e.g., 45-46]
   </ct_lines_to_update>
   <ct_updated_code>
   [replacement code without line numbers]
   </ct_updated_code>
3. You may provide multiple updates if necessary.
4. Maintain the original indentation unless the context changes.
5. Even for single-line edits, specify both start and end lines (e.g., 45-45).

For 'append' tasks:
1. The snippet will not include line numbers.
2. Provide the code to be appended using:
   <ct_updated_code>
   [code to append]
   </ct_updated_code>

Guidelines:
- Make only the changes requested by the user, which will be specified in comments within the code.
- If you have additional suggestions or remarks, include them as short comments in your response snippet.
- Do not write anything outside of the specified XML tags.
- Ensure your response contains only the required XML components.
- Always place XML tags on separate lines from their content.

Analyze the given code, make the requested changes, and provide your response in the specified format.
]],
  show_diff = true,
}

---@param opts Opts
function M.setup(opts)
  opts = opts or {}

  -- Merge models
  if opts.models then
    for k, v in pairs(opts.models) do
      M.opts.models[k] = v
    end
  end

  -- Merge api_types
  if opts.api_types then
    M.opts.api_types = M.opts.api_types or {}
    for k, v in pairs(opts.api_types) do
      M.opts.api_types[k] = v
    end
  end

  -- Update other options
  for k, v in pairs(opts) do
    if k ~= "models" and k ~= "api_types" then
      M.opts[k] = v
    end
  end
end

---@param model_name? string
---@param callback? fun()
function M.select_model(model_name, callback)
  if model_name then
    if M.opts.models[model_name] then
      M.opts.selected_model = model_name
      if callback then
        callback()
      end
    else
      util.notify("Invalid model name. Model not changed.", vim.log.levels.ERROR)
    end
    return
  end
  local model_names = vim.tbl_keys(M.opts.models)
  vim.ui.select(model_names, {
    prompt = "Choose a model:",
    format_item = function(item)
      return item .. (item == M.opts.selected_model and " (current)" or "")
    end,
  }, function(choice)
    if choice then
      M.opts.selected_model = choice
    end
    if callback then
      callback()
    end
  end)
end

---@param start_line integer
---@param end_line integer
---@return string
local function get_code_block(start_line, end_line)
  local lines = vim.fn.getline(start_line, end_line)
  ---@diagnostic disable-next-line: param-type-mismatch
  return table.concat(lines, "\n")
end

local function open_diff_view()
  vim.cmd("buffer " .. M.main_bufnr)
  vim.cmd("wincmd v")
  vim.cmd("buffer " .. M.dup_bufnr)
  vim.cmd("windo diffthis")
  util.switch_to_buf_win(M.main_bufnr)
end

function M.close_diff_view()
  if M.dup_bufnr == -1 then
    util.notify("No diff buffer found open.")
    return
  end
  vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local win_bufnr = vim.api.nvim_win_get_buf(win)
    if win_bufnr == M.dup_bufnr then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_buf_delete(M.dup_bufnr, { force = true })
  vim.cmd("windo diffoff")
  M.dup_bufnr = -1
  util.switch_to_buf_win(M.main_bufnr)
end

---@param is_visual_mode boolean
---@param filetype string
---@param snippet string
---@param start_line? integer
---@return string
local function create_user_prompt(is_visual_mode, filetype, snippet, start_line, instructions)
  return "<ct_language>\n"
    .. filetype
    .. "\n</ct_language>\n"
    .. "<ct_task>\n"
    .. (is_visual_mode and "edit" or "append")
    .. "\n</ct_task>\n"
    .. "<ct_instructions>\n"
    .. instructions
    .. "\n</ct_instructions>\n\n<ct_snippet>\n"
    .. (is_visual_mode and util.add_line_numbers(snippet, start_line) or snippet)
    .. "\n</ct_snippet>"
end

---@param on_start fun()
local function call_api(on_start, prompt_ctx)
  local is_visual_mode = prompt_ctx.is_visual_mode
  local show_diff = prompt_ctx.show_diff
  local filetype = prompt_ctx.filetype
  local start_line = prompt_ctx.start_line
  local end_line = prompt_ctx.end_line
  local snippet = prompt_ctx.snippet
  local instructions = prompt_ctx.instructions
  local prompt = create_user_prompt(is_visual_mode, filetype, snippet, start_line, instructions)

  local model_opts = M.opts.models[M.opts.selected_model] ---@type ModelOpts
  local api_opts = M.opts.api_types[model_opts.api_type] ---@type ApiOpts

  local endpoint = model_opts.endpoint or api_opts.endpoint
  local stream = util.get_first_boolean(true, { model_opts.stream, api_opts.stream, M.opts.stream })
  local get_api_payload = model_opts.get_api_payload or api_opts.get_api_payload
  local get_headers = model_opts.get_headers or api_opts.get_headers
  local extract_assistant_response = model_opts.extract_assistant_response or api_opts.extract_assistant_response
  local extract_text_delta = model_opts.extract_text_delta or api_opts.extract_text_delta

  -- Show loader notification
  util.notify("Thinking...", vim.log.levels.INFO, { timeout = false })

  if
    not get_api_payload
    or not get_headers
    or (not stream and not extract_assistant_response)
    or (stream and not extract_text_delta)
  then
    util.notify("API is not well defined", vim.log.levels.ERROR)
    return
  end

  local body = get_api_payload(prompt, model_opts, api_opts, M.opts)
  local headers = get_headers(model_opts, api_opts, M.opts)
  if not body or not headers then
    return
  end

  ---@type { event: string }
  local state = { event = "" }
  local full_response = ""

  local should_undojoin = false
  local function undojoin()
    if should_undojoin then
      pcall(vim.cmd.undojoin)
    else
      should_undojoin = true
    end
  end

  local max_num_lines_while_appending = 0

  local function redraw()
    undojoin()
    if is_visual_mode then
      util.process_and_apply_patch(full_response, M.dup_bufnr, M.main_bufnr)
    else
      local lines_to_append = util.get_lines_to_append(full_response)
      vim.api.nvim_buf_set_lines(
        M.main_bufnr,
        end_line,
        end_line + max_num_lines_while_appending,
        false,
        lines_to_append
      )
      max_num_lines_while_appending = math.max(max_num_lines_while_appending, #lines_to_append)
    end
    vim.cmd("redraw")
  end

  on_start()

  curl.post(endpoint, {
    body = body,
    headers = headers,
    stream = stream
        and function(_, chunk)
          vim.schedule(function()
            ---@diagnostic disable-next-line:need-check-nil
            local delta = extract_text_delta(chunk, state, model_opts, api_opts, M.opts)
            if not delta then
              return
            end
            util.notify("Modifying the code...", vim.log.levels.INFO, { timeout = false, _replace = true })
            full_response = full_response .. delta
            redraw()
          end)
        end
      or nil,
    callback = stream and function(response_http)
      vim.schedule(function()
        if response_http.status == 200 then
          util.notify("Done!", vim.log.levels.INFO, { timeout = 3000 })
        else
          util.notify(
            "API responded with an error:\n\n" .. vim.inspect(response_http),
            vim.log.levels.ERROR,
            { timeout = 3000 }
          )
        end
        -- Cleanup duplicate buffer if it was created for visual mode without diff
        if is_visual_mode and not show_diff and M.dup_bufnr ~= -1 then
          vim.api.nvim_buf_delete(M.dup_bufnr, { force = true })
          M.dup_bufnr = -1
        end
      end)
    end or function(response_http)
      vim.schedule(function()
        local response_str = response_http.body
        local response = extract_assistant_response(response_str, model_opts, api_opts, M.opts)
        if not response then
          util.notify("No response from the API", vim.log.levels.ERROR)
          return
        end
        full_response = response
        redraw()
        util.notify("Done!", vim.log.levels.INFO, { timeout = 3000 })
        -- Cleanup duplicate buffer if it was created for visual mode without diff
        if is_visual_mode and not show_diff and M.dup_bufnr ~= -1 then
          vim.api.nvim_buf_delete(M.dup_bufnr, { force = true })
          M.dup_bufnr = -1
        end
      end)
    end,
    error_callback = function(err)
      util.notify("Error during generation: " .. tostring(err), vim.log.levels.ERROR)
    end,
  })
end

---@param toggle_show_diff? boolean
function M.call(toggle_show_diff)
  local show_diff = M.opts.show_diff or false
  if toggle_show_diff then
    show_diff = not show_diff
  end

  M.main_bufnr = vim.fn.bufnr()

  local mode = vim.fn.mode()
  local is_visual_mode = mode == "v" or mode == "V" or mode == "\22"
  local filetype = vim.bo.filetype
  local start_line, end_line = util.get_sel_range()
  local snippet = get_code_block(start_line, end_line)

  vim.ui.input({ prompt = "Coddit instructions: " }, function(input)
    local instructions = util.trim(input or "")
    if instructions == "" then
      util.notify("Operation cancelled: no instructions provided.", vim.log.levels.WARN)
      return
    end

    call_api(function()
      if show_diff or is_visual_mode then
        M.dup_bufnr = util.duplicate_buffer(M.main_bufnr, filetype)
        if not M.dup_bufnr or M.dup_bufnr == -1 then
          util.notify("Unable to duplicate the buffer for diff.", vim.log.levels.ERROR)
          return
        end
        vim.api.nvim_set_current_buf(M.main_bufnr)
      end
      if show_diff then
        open_diff_view()
      end
    end, {
      is_visual_mode = is_visual_mode,
      show_diff = show_diff,
      filetype = filetype,
      start_line = start_line,
      end_line = end_line,
      snippet = snippet,
      instructions = instructions,
    })
  end)
end

return M

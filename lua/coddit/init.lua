local curl = require("plenary.curl")
local util = require("coddit.util")

-- XML-like tags constants
local TAG_TASK_OPEN = "<ct_task>"
local TAG_TASK_CLOSE = "</ct_task>"
local TAG_LANG_OPEN = "<ct_language>"
local TAG_LANG_CLOSE = "</ct_language>"
local TAG_SNIPPET_OPEN = "<ct_snippet>"
local TAG_SNIPPET_CLOSE = "</ct_snippet>"
local TAG_LINES_TO_UPDATE_OPEN = "<ct_lines_to_update>"
local TAG_LINES_TO_UPDATE_CLOSE = "</ct_lines_to_update>"
local TAG_UPDATED_CODE_OPEN = "<ct_updated_code>"
local TAG_UPDATED_CODE_CLOSE = "</ct_updated_code>"

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
      -- model_opts, api_opts, global_opts are available from _handle_stream_chunk if needed in future.
      extract_text_delta = function(response, state)
        if not response then
          return nil
        end
        local chunk_body = response:match("^data: (.+)$")
        if chunk_body and state.event == "content_block_delta" then
          local ok, chunk_json = pcall(vim.fn.json_decode, chunk_body)
          if not ok then
            util.notify("Error decoding Anthropic stream chunk: " .. chunk_body, vim.log.levels.WARN)
            return nil
          end

          if chunk_json and chunk_json.delta and type(chunk_json.delta.text) == "string" then
            return chunk_json.delta.text
          else
            -- Log if structure is not as expected but decoding was ok
            util.notify("Unexpected JSON structure in Anthropic stream chunk: " .. chunk_body, vim.log.levels.WARN)
            return nil
          end
        else
          -- This part is for Anthropic's event stream, not an error.
          local new_event = response:match("^event: (.+)$")
          if new_event then
            state.event = new_event
          end
          -- If it's not a content_block_delta and not an event line we recognize,
          -- or if chunk_body is nil, we should return nil as no text delta was extracted.
          return nil
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
      -- model_opts, api_opts, global_opts are available from _handle_stream_chunk if needed in future.
      -- state is not used by OpenAI spec for delta, but kept for signature consistency.
      extract_text_delta = function(response)
        if not response then
          return nil
        end
        local chunk_body = response:match("^data: (.+)$")
        if chunk_body then
          if chunk_body == "[DONE]" then
            return nil -- Explicitly return nil for [DONE]
          end
          local ok, chunk_json = pcall(vim.fn.json_decode, chunk_body)
          if not ok then
            util.notify("Error decoding OpenAI stream chunk JSON: " .. chunk_body, vim.log.levels.WARN)
            return nil
          end

          if chunk_json and type(chunk_json.choices) == "table" and #chunk_json.choices > 0 then
            local choice = chunk_json.choices[1]
            if choice and choice.delta and type(choice.delta.content) == "string" then
              return choice.delta.content
            elseif choice and choice.delta and (choice.delta.content == nil or choice.delta.content == vim.NIL) then
              -- This can happen if the delta is just a role update or finish_reason, which is fine.
              return "" -- Return empty string to signify no text delta, but not an error.
            else
              util.notify(
                "Unexpected JSON structure in OpenAI stream chunk (delta.content missing or not string): " .. chunk_body,
                vim.log.levels.WARN
              )
              return nil
            end
          else
            util.notify(
              "Unexpected JSON structure in OpenAI stream chunk (choices missing or empty): " .. chunk_body,
              vim.log.levels.WARN
            )
            return nil
          end
        end
        return nil -- Default return if chunk_body is nil
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
            return nil -- Explicitly return nil for [DONE]
          end
          local ok, chunk_json = pcall(vim.fn.json_decode, chunk_body)
          if not ok then
            util.notify("Error decoding OpenAI-O1 stream chunk JSON: " .. chunk_body, vim.log.levels.WARN)
            return nil
          end

          if chunk_json and type(chunk_json.choices) == "table" and #chunk_json.choices > 0 then
            local choice = chunk_json.choices[1]
            if choice and choice.delta and type(choice.delta.content) == "string" then
              return choice.delta.content
            elseif choice and choice.delta and (choice.delta.content == nil or choice.delta.content == vim.NIL) then
              -- This can happen if the delta is just a role update or finish_reason, which is fine.
              return "" -- Return empty string to signify no text delta, but not an error.
            else
              util.notify(
                "Unexpected JSON structure in OpenAI-O1 stream chunk (delta.content missing or not string): "
                  .. chunk_body,
                vim.log.levels.WARN
              )
              return nil
            end
          else
            util.notify(
              "Unexpected JSON structure in OpenAI-O1 stream chunk (choices missing or empty): " .. chunk_body,
              vim.log.levels.WARN
            )
            return nil
          end
        end
        return nil -- Default return if chunk_body is nil
      end,
    },
  },
  models = {
    ["haiku"] = {
      model = "claude-3-5-haiku-latest",
      api_type = "anthropic",
    },
    ["sonnet"] = {
      model = "claude-3-7-sonnet-latest",
      api_type = "anthropic",
    },
    ["gpt-4o"] = {
      model = "gpt-4o",
      api_type = "openai",
    },
    ["gpt-4.1"] = {
      model = "gpt-4.1-2025-04-14",
      api_type = "openai",
    },
    ["o4-mini"] = {
      model = "o4-mini",
      api_type = "openai-o1",
      max_tokens = 20000,
    },
    ["deepseek-v3"] = {
      model = "deepseek-chat",
      api_type = "openai",
      api_key = os.getenv("DEEPSEEK_API_KEY"),
      endpoint = "https://api.deepseek.com/chat/completions",
    },
  },
  selected_model = "sonnet",
  max_tokens = 1024,
  system_prompt = "You are an AI coding assistant that updates code directly in the editor. Your task is to modify or append code based on the given instructions. You will receive input in the following format:\n\n"
    .. TAG_LANG_OPEN
    .. "[programming language]"
    .. TAG_LANG_CLOSE
    .. "\n"
    .. TAG_SNIPPET_OPEN
    .. "[code snippet]"
    .. TAG_SNIPPET_CLOSE
    .. "\n"
    .. TAG_TASK_OPEN
    .. "[append or edit]"
    .. TAG_TASK_CLOSE
    .. "\n\nFor 'edit' tasks:\n1. The snippet will include line numbers.\n2. Provide your changes using the following format, with XML tags on separate lines:\n   "
    .. TAG_LINES_TO_UPDATE_OPEN
    .. "\n   [line range to edit, e.g., 45-46]\n   "
    .. TAG_LINES_TO_UPDATE_CLOSE
    .. "\n   "
    .. TAG_UPDATED_CODE_OPEN
    .. "\n   [replacement code without line numbers]\n   "
    .. TAG_UPDATED_CODE_CLOSE
    .. "\n3. You may provide multiple updates if necessary.\n4. Maintain the original indentation unless the context changes.\n5. Even for single-line edits, specify both start and end lines (e.g., 45-45).\n\nFor 'append' tasks:\n1. The snippet will not include line numbers.\n2. Provide the code to be appended using:\n   "
    .. TAG_UPDATED_CODE_OPEN
    .. "\n   [code to append]\n   "
    .. TAG_UPDATED_CODE_CLOSE
    .. "\n\nGuidelines:\n- Make only the changes requested by the user, which will be specified in comments within the code.\n- If you have additional suggestions or remarks, include them as short comments in your response snippet.\n- Do not write anything outside of the specified XML tags.\n- Ensure your response contains only the required XML components.\n- Always place XML tags on separate lines from their content.\n\nAnalyze the given code, make the requested changes, and provide your response in the specified format.",
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

  -- Validate selected_model after all options are merged
  if not M.opts.models[M.opts.selected_model] then
    util.notify(
      string.format(
        "Selected model '%s' is invalid or not found in the available models. Please check your configuration.",
        M.opts.selected_model
      ),
      vim.log.levels.ERROR
    )
    -- Attempt to set a fallback model
    local fallback_model_name = "sonnet" -- Default fallback
    if M.opts.models[fallback_model_name] then
      M.opts.selected_model = fallback_model_name
      util.notify(string.format("Falling back to model '%s'.", fallback_model_name), vim.log.levels.WARN)
    else
      -- If 'sonnet' isn't there, try the first available model
      local first_model_key = next(M.opts.models)
      if first_model_key then
        M.opts.selected_model = first_model_key
        util.notify(string.format("Falling back to first available model '%s'.", first_model_key), vim.log.levels.WARN)
      else
        -- This is a critical state: no valid selected_model and no fallbacks.
        util.notify("No valid models available after setup. Coddit might not function correctly.", vim.log.levels.ERROR)
        M.opts.selected_model = nil -- Indicate that it's unusable
      end
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
local function create_user_prompt(is_visual_mode, filetype, snippet, start_line)
  return TAG_TASK_OPEN
    .. "\n"
    .. (is_visual_mode and "edit" or "append")
    .. "\n"
    .. TAG_TASK_CLOSE
    .. "\n"
    .. TAG_LANG_OPEN
    .. "\n"
    .. filetype
    .. "\n"
    .. TAG_LANG_CLOSE
    .. "\n\n"
    .. TAG_SNIPPET_OPEN
    .. "\n"
    .. (is_visual_mode and util.add_line_numbers(snippet, start_line) or snippet)
    .. "\n"
    .. TAG_SNIPPET_CLOSE
end

---@return table? { filetype: string, is_visual_mode: boolean, start_line: integer, end_line: integer, snippet: string }
local function _get_request_context()
  local mode = vim.fn.mode()
  local filetype = vim.bo.filetype
  local is_visual_mode = mode == "v" or mode == "V" or mode == " "

  local start_line, end_line = util.get_sel_range()
  local snippet = get_code_block(start_line, end_line)

  return {
    filetype = filetype,
    is_visual_mode = is_visual_mode,
    start_line = start_line,
    end_line = end_line,
    snippet = snippet,
  }
end

---@param model_opts ModelOpts
---@param api_opts ApiOpts
---@param global_opts Opts
---@return table? { endpoint: string, stream: boolean, get_api_payload: function, get_headers: function, extract_assistant_response: (function|nil), extract_text_delta: (function|nil) }
local function _prepare_api_config(model_opts, api_opts, global_opts)
  local endpoint = model_opts.endpoint or api_opts.endpoint
  local stream = util.get_first_boolean(true, { model_opts.stream, api_opts.stream, global_opts.stream })
  local get_api_payload = model_opts.get_api_payload or api_opts.get_api_payload
  local get_headers = model_opts.get_headers or api_opts.get_headers
  local extract_assistant_response = model_opts.extract_assistant_response or api_opts.extract_assistant_response
  local extract_text_delta = model_opts.extract_text_delta or api_opts.extract_text_delta

  if
    not get_api_payload
    or not get_headers
    or (not stream and not extract_assistant_response)
    or (stream and not extract_text_delta)
  then
    util.notify("API is not well defined for the selected model/API type.", vim.log.levels.ERROR)
    return nil
  end

  return {
    endpoint = endpoint,
    stream = stream,
    get_api_payload = get_api_payload,
    get_headers = get_headers,
    extract_assistant_response = extract_assistant_response,
    extract_text_delta = extract_text_delta,
  }
end

---@param on_start fun()
local function call_api(on_start)
  local request_context = _get_request_context()
  if not request_context then
    util.notify("Could not get request context.", vim.log.levels.ERROR)
    return
  end

  local prompt = create_user_prompt(
    request_context.is_visual_mode,
    request_context.filetype,
    request_context.snippet,
    request_context.start_line
  )

  local current_model_opts = M.opts.models[M.opts.selected_model]
  if not current_model_opts then
    util.notify("Selected model configuration not found: " .. M.opts.selected_model, vim.log.levels.ERROR)
    return
  end
  current_model_opts = current_model_opts ---@type ModelOpts

  local current_api_opts = M.opts.api_types[current_model_opts.api_type]
  if not current_api_opts then
    util.notify("API type configuration not found for: " .. current_model_opts.api_type, vim.log.levels.ERROR)
    return
  end
  current_api_opts = current_api_opts ---@type ApiOpts

  local api_config = _prepare_api_config(current_model_opts, current_api_opts, M.opts)

  if not api_config then
    -- _prepare_api_config will show a notification
    return
  end

  -- Show loader notification
  util.notify("Thinking...", vim.log.levels.INFO, { timeout = false })

  local body = api_config.get_api_payload(prompt, current_model_opts, current_api_opts, M.opts)
  local headers = api_config.get_headers(current_model_opts, current_api_opts, M.opts)
  -- get_api_payload and get_headers might return nil or false, handle this
  if not (body and headers) then
    util.notify("Failed to generate API payload or headers.", vim.log.levels.ERROR, { _replace = true }) -- Ensure "Thinking..." is replaced
    return
  end

  ---@type { event: string }
  local state = { event = "" }
  local full_response_table = { value = "" } -- Use a table to pass by reference

  local should_undojoin = false
  local function undojoin()
    if should_undojoin then
      pcall(vim.cmd.undojoin)
    else
      should_undojoin = true
    end
  end

  local max_num_lines_while_appending = 0

  -- Updated redraw function to accept parameters
  ---@param current_full_response string
  ---@param current_is_visual_mode boolean
  ---@param current_end_line number
  local function redraw(current_full_response, current_is_visual_mode, current_end_line)
    undojoin()
    if current_is_visual_mode then
      util.process_and_apply_patch(current_full_response, M.dup_bufnr, M.main_bufnr)
    else
      local lines_to_append = util.get_lines_to_append(current_full_response)
      vim.api.nvim_buf_set_lines(
        M.main_bufnr,
        current_end_line,
        current_end_line + max_num_lines_while_appending,
        false,
        lines_to_append
      )
      max_num_lines_while_appending = math.max(max_num_lines_while_appending, #lines_to_append)
    end
    vim.cmd("redraw")
  end

  ---@param chunk string
  ---@param _full_response_table { value: string }
  ---@param _state { event: string }
  ---@param extract_text_delta_func fun(response: string, state?: { event: string }, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string|nil
  ---@param model_opts ModelOpts
  ---@param api_opts ApiOpts
  ---@param global_opts Opts
  ---@param redraw_func function
  ---@param redraw_func_params table { full_response: string, is_visual_mode: boolean, end_line: number }
  local function _handle_stream_chunk(
    chunk,
    _full_response_table,
    _state,
    extract_text_delta_func,
    model_opts,
    api_opts,
    global_opts,
    redraw_func,
    redraw_func_params
  )
    if not extract_text_delta_func then
      util.notify("extract_text_delta is not defined for this API type", vim.log.levels.ERROR, { _replace = true })
      return
    end
    local delta = extract_text_delta_func(chunk, _state, model_opts, api_opts, global_opts)
    if not delta then
      return
    end
    util.notify("Modifying the code...", vim.log.levels.INFO, { timeout = false, _replace = true })
    _full_response_table.value = _full_response_table.value .. delta
    redraw_func_params.full_response = _full_response_table.value -- Update the full_response for redraw
    redraw_func(redraw_func_params.full_response, redraw_func_params.is_visual_mode, redraw_func_params.end_line)
  end

  ---@param response_http table The HTTP response object from curl.
  local function _finalize_stream(response_http)
    if response_http.status == 200 then
      util.notify("Done!", vim.log.levels.INFO, { timeout = 3000 }) -- Should replace previous "Modifying..."
    else
      local error_message = "API stream finalization error: " .. response_http.status
      local body_snippet = "N/A"
      if type(response_http.body) == "string" then
        body_snippet = string.sub(response_http.body, 1, 200)
      elseif response_http.body ~= nil then
        body_snippet = vim.inspect(response_http.body)
        body_snippet = string.sub(body_snippet, 1, 200)
      end
      util.notify(
        error_message .. "\nBody: " .. body_snippet,
        vim.log.levels.ERROR,
        { timeout = 5000, _replace = true }
      )
    end
  end

  ---@param response_http table The HTTP response object from curl.
  ---@param _full_response_table { value: string }
  ---@param extract_assistant_response_func fun(response: string, model_opts?: ModelOpts, api_opts?: ApiOpts, opts?: Opts): string|nil
  ---@param model_opts ModelOpts
  ---@param api_opts ApiOpts
  ---@param global_opts Opts
  ---@param redraw_func function
  ---@param redraw_func_params table { full_response: string, is_visual_mode: boolean, end_line: number }
  local function _handle_non_streamed_response(
    response_http,
    _full_response_table,
    extract_assistant_response_func,
    model_opts,
    api_opts,
    global_opts,
    redraw_func,
    redraw_func_params
  )
    if response_http.status ~= 200 then
      local error_message = "API error: " .. response_http.status
      local body_snippet = "N/A"
      if type(response_http.body) == "string" then
        body_snippet = string.sub(response_http.body, 1, 200)
      elseif response_http.body ~= nil then
        body_snippet = vim.inspect(response_http.body)
        body_snippet = string.sub(body_snippet, 1, 200)
      end
      util.notify(
        error_message .. "\nBody: " .. body_snippet,
        vim.log.levels.ERROR,
        { timeout = 5000, _replace = true }
      )
      return
    end

    if not extract_assistant_response_func then
      util.notify(
        "extract_assistant_response is not defined for this API type",
        vim.log.levels.ERROR,
        { _replace = true }
      )
      return
    end

    local response_str = response_http.body
    local response = extract_assistant_response_func(response_str, model_opts, api_opts, global_opts)
    if not response then
      util.notify("No response content from the API or failed to extract.", vim.log.levels.ERROR, { _replace = true })
      return
    end

    _full_response_table.value = response
    redraw_func_params.full_response = _full_response_table.value -- Update the full_response for redraw
    redraw_func(redraw_func_params.full_response, redraw_func_params.is_visual_mode, redraw_func_params.end_line)
    util.notify("Done!", vim.log.levels.INFO, { timeout = 3000 })
  end

  on_start()

  curl.post(api_config.endpoint, {
    body = body,
    headers = headers,
    stream = api_config.stream
        and function(_, chunk)
          vim.schedule(function()
            local redraw_params = {
              full_response = full_response_table.value,
              is_visual_mode = request_context.is_visual_mode,
              end_line = request_context.end_line,
            }
            _handle_stream_chunk(
              chunk,
              full_response_table,
              state,
              api_config.extract_text_delta,
              current_model_opts,
              current_api_opts,
              M.opts,
              redraw, -- Pass the redraw function
              redraw_params
            )
          end)
        end
      or nil,
    callback = api_config.stream and function(response_http)
      vim.schedule(function()
        _finalize_stream(response_http)
      end)
    end or function(response_http)
      vim.schedule(function()
        local redraw_params = {
          full_response = full_response_table.value, -- Though this will be overwritten by the full response
          is_visual_mode = request_context.is_visual_mode,
          end_line = request_context.end_line,
        }
        _handle_non_streamed_response(
          response_http,
          full_response_table,
          api_config.extract_assistant_response,
          current_model_opts,
          current_api_opts,
          M.opts,
          redraw, -- Pass the redraw function
          redraw_params
        )
      end)
    end,
    error_callback = function(err)
      util.notify("Error during API call: " .. tostring(err), vim.log.levels.ERROR, { _replace = true })
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

  call_api(function()
    if show_diff then
      local filetype = vim.bo.filetype
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
  end)
end

return M

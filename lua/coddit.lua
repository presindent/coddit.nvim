local curl = require("plenary.curl")
local util = require("util")

local M = {}

M.dup_bufnr = -1
M.main_bufnr = -1

---@class ModelOpts
---@field endpoint? string
---@field model? string
---@field api_type? string
---@field api_key? string
---@field system_prompt? string
---@field anthropic_version? string
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
---@field anthropic_version? string
---@field system_prompt? string
---@field stream? boolean
---@field show_diff? boolean

---@alias PromptMode "append" | "replace"

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
        local stream = util.get_first_boolean(true, model_opts.stream, api_opts.stream, M.opts.stream)

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
            vim.notify("Error decoding chunk JSON", vim.log.levels.ERROR)
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
        local stream = util.get_first_boolean(true, model_opts.stream, api_opts.stream, M.opts.stream)

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
            vim.notify("Error decoding chunk JSON", vim.log.levels.ERROR)
          end
        end
      end,
    },
  },
  models = {
    ["haiku"] = {
      model = "claude-3-haiku-20240307",
      api_type = "anthropic",
    },
    ["sonnet"] = {
      model = "claude-3-5-sonnet-20240620",
      api_type = "anthropic",
    },
    ["gpt-4o"] = {
      model = "gpt-4o",
      api_type = "openai",
    },
  },
  selected_model = "sonnet",
  max_tokens = 1024,
  anthropic_version = "2023-06-01",
  system_prompt = [[
You are an AI coding assistant integrated into a Neovim editor instance. Your primary role is to assist users with various programming tasks by modifying existing code snippets or generating new code based on given prompts.

First, identify whether you will be replacing the provided snippet or appending to it. The type may be "append" or "replace".
<type>
{{TYPE}}
</type>

Next, identify the programming language you'll be working with:
<language>
{{LANGUAGE}}
</language>

If no language is specified above, you should auto-detect the language based on the provided code snippet or context. If the language is not discernible, ask the user for clarification.

Now, examine the code snippet you'll be working with:
<snippet>
{{SNIPPET}}
</snippet>

If no snippet is provided, you'll be generating new code based on the prompt.

Additional context for the task:
<context>
{{CONTEXT}}
</context>

Your task is defined by the following prompt:
<prompt>
{{PROMPT}}
</prompt>

Follow these instructions to complete the task:

1. Analyze the inputs:
   - If both a code snippet and a prompt are provided, focus on modifying the existing code or adding to it according to the prompt's instructions and the type of the prompt.
   - If only a code snippet is provided, analyze the comments and annotations to determine the objective. If the objective is unclear, respond with a comment seeking clarification.
   - If only a prompt is provided, generate new code based on the prompt's requirements.
   - If neither a code snippet nor a prompt is provided, respond with a comment asking for more information.

2. Perform the required task:
   - For code modifications, carefully edit the existing code to meet the prompt's requirements while maintaining the original structure and style where possible.
   - Existing code may be used for examples or context. Refrain from replacing such code unless specifically asked to.
   - For new code generation, create clean, efficient, and well-commented code that fulfills the prompt's specifications.
   - Ensure that your code follows best practices and conventions for the programming language in use.
   - Delete the comments you deem unnecessary, including the imperative ones directing you to write code.

3. Provide explanations:
   - If you've made significant changes or additions to the code, include brief comments explaining your modifications.
   - For newly generated code, add comments to explain complex logic or important design decisions.

4. Output format:
   - Present your final code inside <code> tags. DO NOT use markdown code blocks for the code.
    - If the type of the prompt is "append", just provide the code that needs to be appended.
    - If the type is "replace" instead, furnish the entire modified code.
    - Unless asked to, do not write placeholders for the dependencies such as functions not included in the provided context. Simply assume that such functions/symbols exist, unless told otherwise.
   - If you need to provide additional explanations or ask for clarifications, use comments within the code.
   - Use a minimal number of comments, and avoid explaining the obvious parts.

5. Error handling and edge cases:
   - If you encounter any potential issues or edge cases in the task, address them in your code and explain your approach in comments.
   - If the task seems impossible or contradictory, explain the issue inside <error> tags and suggest possible solutions or ask for clarification.

6. Seeking clarification:
   - If any part of the task is unclear or you need more information, respond with a comment (starting with `//`) asking for the specific details you need.
   - Only proceed with code generation when you have a perfectly discernible objective.

Here's an example of how your response might be structured:

<code>
// Modified/Generated code here
function exampleFunction() {
  // Your code implementation
  // With explanatory comments as needed
}
</code>

DO NOT write anything, including courtesies and language artefacts, outside the XML tags.

Remember, your goal is to provide helpful, accurate, and efficient coding assistance. Always prioritize code quality, readability, and adherence to the user's requirements.
]],
  show_diff = true,
}

---@param response string
---@return string[]
local function extract_code_lines(response)
  local lines = {}
  local in_code_block = false
  local all_lines = {}

  for line in response:gmatch("([^\r\n]*)[\r\n]?") do
    table.insert(all_lines, line)
  end

  -- Find the last </code> tag
  local last_code_end = #all_lines
  for i = #all_lines, 1, -1 do
    if all_lines[i]:match("^</code>$") then
      last_code_end = i
      break
    end
  end

  for i = 1, last_code_end - 1 do
    local line = all_lines[i]
    if line:match("^<code>$") then
      in_code_block = true
    elseif in_code_block then
      table.insert(lines, line)
    end
  end

  return lines
end

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
      vim.notify("Invalid model name. Model not changed.", vim.log.levels.ERROR)
    end
    return
  end
  local model_names = vim.tbl_keys(M.opts.models)
  table.sort(model_names)
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
    vim.notify("No diff buffer found open.")
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
---@return string
local function create_user_prompt(is_visual_mode, filetype, snippet)
  return "<type>\n"
    .. (is_visual_mode and "replace" or "append")
    .. "\n</type>\n"
    .. "<language>\n"
    .. filetype
    .. "\n</language>\n\n<snippet>\n"
    .. snippet
    .. "\n</snippet>"
end

---@param on_start fun()
local function call_api(on_start)
  local mode = vim.fn.mode()
  local filetype = vim.bo.filetype
  local is_visual_mode = mode == "v" or mode == "V" or mode == " "

  local start_line, end_line = util.get_sel_range()
  local snippet = get_code_block(start_line, end_line)
  local prompt = create_user_prompt(is_visual_mode, filetype, snippet)

  local model_opts = M.opts.models[M.opts.selected_model] ---@type ModelOpts
  local api_opts = M.opts.api_types[model_opts.api_type] ---@type ApiOpts

  local endpoint = model_opts.endpoint or api_opts.endpoint
  local stream = util.get_first_boolean(true, model_opts.stream, api_opts.stream, M.opts.stream)
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
    vim.notify("API is not well defined", vim.log.levels.ERROR)
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

  local visible_response = ""
  local char_index = 0

  local repl_start_line = is_visual_mode and start_line or end_line + 1

  local should_undojoin = false
  local function undojoin()
    if should_undojoin then
      pcall(vim.cmd.undojoin)
    else
      should_undojoin = true
    end
  end

  ---@param kn integer
  local function add_char_to_visible_response(kn)
    if kn ~= #full_response then
      return
    end

    if char_index <= #full_response then
      if #visible_response then
        undojoin()
        vim.cmd("redraw")
      end

      if stream then
        visible_response = visible_response .. full_response:sub(char_index, char_index)
      else
        visible_response = full_response
      end

      local total_chars = #full_response - char_index + 1
      local total_duration = 100
      local delay = math.min(total_duration / total_chars, 10)

      if stream then
        vim.defer_fn(function()
          add_char_to_visible_response(#full_response)
        end, delay)
      end

      local lines = extract_code_lines(visible_response)
      vim.api.nvim_buf_set_lines(M.main_bufnr, repl_start_line - 1, end_line, false, lines)
      end_line = repl_start_line + #lines - 1
      char_index = char_index + 1
    end
  end

  on_start()

  ---@param response string
  ---@param msg string
  ---@param level integer|nil
  local function callback(response, msg, level)
    add_char_to_visible_response(#response)
    undojoin()
    vim.cmd("redraw")
    vim.notify(msg, level)
  end

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
            full_response = full_response .. delta
            add_char_to_visible_response(#full_response)
          end)
        end
      or nil,
    callback = stream and function()
      vim.schedule(function()
        callback(full_response, "Streaming completed", vim.log.levels.INFO)
      end)
    end or function(response_http)
      vim.schedule(function()
        local response_str = response_http.body
        local response = extract_assistant_response(response_str, model_opts, api_opts, M.opts)
        if not response then
          vim.notify("No response from the API", vim.log.levels.ERROR)
          return
        end
        full_response = response
        callback(full_response, "Done", vim.log.levels.INFO)
      end)
    end,
    error_callback = function(err)
      vim.schedule(function()
        callback(full_response, "Error during generation: " .. tostring(err), vim.log.levels.ERROR)
      end)
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
        vim.notify("Unable to duplicate the buffer for diff.", vim.log.levels.ERROR)
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

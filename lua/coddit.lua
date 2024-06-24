local util = require("util")

local M = {}

M.dup_bufnr = -1
M.main_bufnr = -1

---@param api_type "anthropic" | "openai"
local function default_endpoint(api_type)
   if api_type == "anthropic" then
      return "https://api.anthropic.com/v1/messages"
   elseif api_type == "openai" then
      return "https://api.openai.com/v1/chat/completions"
   end
end

---@class Opts
---@field models? table<string, {endpoint?: string, model: string, api_type: "anthropic" | "openai", api_key?: string, system_prompt?: string}>
---@field selected_model? string
---@field max_tokens? number
---@field anthropic_version? string
---@field system_prompt? string

---@type Opts
M.opts = {
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
   selected_model = "gpt-4o",
   max_tokens = 1024,
   anthropic_version = "2023-06-01",
   system_prompt = [[
Determine if the task is "append" or "replace": <type>{{TYPE}}</type>. Identify the programming language:
<language>{{LANGUAGE}}</language>. Auto-detect or ask if unspecified. Review the code snippet:
<snippet>{{SNIPPET}}</snippet>. Generate new code if no snippet is provided. Consider additional context:
<context>{{CONTEXT}}</context>. Follow the task prompt: <prompt>{{PROMPT}}</prompt>. Modify or append based on the
prompt, or generate new code. Ask for more information if inputs are unclear. Maintain structure and style. Create
clean, efficient, well-commented code. Do not venture out of the current code context. Do not provide example usage
unless asked to. Follow best practices. Do not create functions unless asked for or absolutely necessary. Provide final
code inside <code> tags without enclosing in backticks. Provide only appended code if "append". Provide entire modified
code if "replace". Assume dependencies exist unless told otherwise. Remove unnecessary comments. Comment on significant
changes. Use comments for explanations or clarifications. Address potential issues and edge cases. Explain issues
inside <error> tags if the task is impossible or contradictory. Ask for specific details if needed. Prioritize code
quality, readability, and adherence to requirements.
]],
}

---@param opts? Opts Table of configuration options (optional)
function M.setup(opts)
   opts = opts or {}

   -- Merge models
   if opts.models then
      for k, v in pairs(opts.models) do
         M.opts.models[k] = v
      end
   end

   -- Update other options
   for k, v in pairs(opts) do
      if k ~= "models" then
         M.opts[k] = v
      end
   end
end

--- @param model_name? string
function M.select_model(model_name)
   if model_name then
      if M.opts.models[model_name] then
         M.opts.selected_model = model_name
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
   end)
end

local function get_api_payload(model_opts, system_prompt, prompt)
   if model_opts.get_api_payload then
      return model_opts.get_api_payload(system_prompt, prompt)
   end

   local base_payload = {
      model = model_opts.model,
      max_tokens = M.opts.max_tokens,
   }
   if model_opts.api_type == "anthropic" then
      base_payload.system = system_prompt
      base_payload.messages = {
         {
            role = "user",
            content = prompt,
         },
      }
   elseif model_opts.api_type == "openai" then
      base_payload.messages = {
         {
            role = "system",
            content = system_prompt,
         },
         {
            role = "user",
            content = prompt,
         },
      }
   else
      vim.notify("Unsupported API type: " .. tostring(model_opts.api_type), vim.log.levels.ERROR)
      return
   end
   return vim.fn.json_encode(base_payload)
end

local function get_headers(model_opts)
   if model_opts.get_headers then
      return model_opts.get_headers()
   end

   local base_headers = {
      "Content-Type: application/json",
   }
   if model_opts.api_type == "anthropic" then
      table.insert(base_headers, "X-API-Key: " .. (model_opts.api_key or os.getenv("ANTHROPIC_API_KEY")))
      table.insert(base_headers, "anthropic-version: " .. (model_opts.anthropic_version or M.opts.anthropic_version))
   elseif model_opts.api_type == "openai" then
      table.insert(base_headers, "Authorization: Bearer " .. (model_opts.api_key or os.getenv("OPENAI_API_KEY")))
   else
      vim.notify("Unsupported API type: " .. tostring(model_opts.api_type), vim.log.levels.ERROR)
      return
   end
   return base_headers
end

local function get_curl_command(model_opts, data)
   local endpoint = model_opts.endpoint or default_endpoint(model_opts.api_type)
   local data_esc = data:gsub('[\\"$]', "\\%0")

   local headers = get_headers(model_opts)
   if not headers then
      return
   end
   local header_str = table.concat(
      vim.tbl_map(function(header)
         return string.format('--header "%s"', header)
      end, headers),
      " "
   )
   return string.format('curl -s %s %s --data "%s"', endpoint, header_str, data_esc)
end

local function call_api(prompt)
   local model_opts = M.opts.models[M.opts.selected_model]

   local system_prompt = model_opts.system_prompt or M.opts.system_prompt

   local data = get_api_payload(model_opts, system_prompt, prompt)
   if not data then
      return
   end

   local curl_command = get_curl_command(model_opts, data)
   if not curl_command then
      return
   end

   local response_str = vim.fn.system(curl_command)

   if vim.v.shell_error ~= 0 then
      vim.notify("Failed to execute cURL.", vim.log.levels.ERROR)
      return nil
   end

   local response = vim.fn.json_decode(response_str)

   local code
   if response then
      if model_opts.api_type == "anthropic" then
         if response.content and response.content[1] then
            code = response.content[1].text
         else
            vim.notify("Unexpected response from the API.", vim.log.levels.ERROR)
         end
      elseif model_opts.api_type == "openai" then
         if response.choices and response.choices[1] then
            code = response.choices[1].message.content
         else
            vim.notify("Unexpected response from the API.", vim.log.levels.ERROR)
         end
      end
   else
      vim.notify("No response from the API.", vim.log.levels.ERROR)
   end
   return code
end

local function get_code_block(start_line, end_line)
   local lines = vim.fn.getline(start_line, end_line)
   ---@diagnostic disable-next-line: param-type-mismatch
   return table.concat(lines, "\n")
end

---@param text string
local function extract_response_code(text)
   local start_tag = "<code>"
   local end_tag = "</code>"

   local start_pos = text:find(start_tag)
   if not start_pos then
      return nil, "No <code> tag found in the response."
   end

   local end_pos = text:find(end_tag, start_pos + #start_tag)
   if not end_pos then
      return nil, "No </code> tag found in the response."
   end

   return text:sub(start_pos + #start_tag + 1, end_pos - 1)
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

---@param show_diff? boolean
function M.call(show_diff)
   if show_diff == nil then
      show_diff = true
   end

   local mode = vim.fn.mode()
   local filetype = vim.bo.filetype
   M.main_bufnr = vim.fn.bufnr()

   local is_visual_mode = mode == "v" or mode == "V" or mode == " "
   local start_line, end_line = util.get_sel_range(is_visual_mode)
   local snippet = get_code_block(start_line, end_line)

   -- TODO: Add the ability to add a textual prompt.
   -- TODO: Add the ability to specify more context.

   local prompt = "<type>\n"
      .. (is_visual_mode and "replace" or "append")
      .. "\n</type>\n"
      .. "<language>\n"
      .. filetype
      .. "\n</language>\n\n<snippet>\n"
      .. snippet
      .. "\n</snippet>"

   local response = call_api(prompt)
   if response then
      local code, error = extract_response_code(response)
      if code then
         if show_diff then
            M.dup_bufnr = util.duplicate_buffer(M.main_bufnr, filetype)
            if not M.dup_bufnr or M.dup_bufnr == -1 then
               vim.notify("Unable to duplicate the buffer for diff.", vim.log.levels.ERROR)
               return
            end
         end

         local lines = {}
         for line in code:gsub("[\r\n]*$", "\n"):gmatch("([^\r\n]*)[\r\n]") do
            table.insert(lines, line)
         end

         local repl_start_line = is_visual_mode and start_line or end_line
         vim.api.nvim_buf_set_lines(M.main_bufnr, repl_start_line - 1, end_line, false, lines)

         if show_diff then
            open_diff_view()
         end
      elseif error then
         vim.notify(error, vim.log.levels.ERROR)
      end
   end
end

return M

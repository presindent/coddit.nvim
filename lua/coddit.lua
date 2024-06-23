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
---@field models? table<string, {endpoint?: string, model: string, api_type: "anthropic" | "openai", api_key?: string}>
---@field selected_model? string
---@field max_tokens? number
---@field anthropic_version? string

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
   local data_esc = data:gsub("\\", "\\\\"):gsub('"', '\\"')

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
   local system_prompt =
      [[You are an AI coding assistant integrated into a Neovim editor instance. Your primary role is to assist users with various programming tasks by modifying existing code snippets or generating new code based on given prompts.

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

Remember, your goal is to provide helpful, accurate, and efficient coding assistance. Always prioritize code quality, readability, and adherence to the user's requirements.]]

   local model_opts = M.opts.models[M.opts.selected_model]

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
         for line in code:gmatch("[^\r\n]+") do
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

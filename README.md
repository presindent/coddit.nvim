# coddit – with LLMs

coddit.nvim is a Neovim plugin to seamlessly harness coding capabilities of LLMs on your projects. Just select the code and ask away.

> (α) You can now also ask ChatGPT to assist you while coding, directly in Neovim, via [coddit.py](https://github.com/presindent/coddit.py) and [coddit Chrome extension](https://github.com/presindent/coddit-chrome).

## Showcase

<table>
<tbody>
<tr>
<td><video src="https://github.com/presindent/coddit.nvim/assets/115044400/185de060-7fcd-42d2-8ec7-0e59b68d24a6"/></td>
<td><video src="https://github.com/presindent/coddit.nvim/assets/115044400/e16bfd69-4076-4b1d-8b2f-191f6b9536f5"/></td>
</tr>
</tbody>
</table>

## Setup

The following guide is specific to the [lazy.nvim](https://github.com/folke/lazy.nvim) plugin manager.

### Installation

Add the following table to your lazy.nvim configuration for a default setup using Anthropic's Claude Sonnet 3.5.

```lua
{
  "presindent/coddit.nvim",
  lazy = false,
  branch = "main",
}
```

### Customization

For custom model configurations, use an expanded setup such as this:

```lua
{
  "presindent/coddit.nvim",
  lazy = false,
  config = function()
    require("coddit").setup({
      models = {
        ["haiku"] = {
          model = "claude-3-haiku-20240307",
          api_type = "anthropic",
        },
        ["sonnet"] = {
          model = "claude-3-5-sonnet-latest",
          api_type = "anthropic",
        },
        ["gpt-4o"] = {
          model = "gpt-4o",
          api_type = "openai",
        },
      },
      selected_model = "sonnet",  -- set this to "gpt-4o" to use OpenAI's GPT-4O
      max_tokens = 1024,
      anthropic_version = "2023-06-01",
      stream = true,  -- set this to false to disable streaming
      show_diff = true,  -- set this to false to skip diffview
    })
  end,
}
```

**Note:** coddit.nvim uses `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` environment variables by default for API keys. You may custom keys using `api_key` attribute in a model table during the setup.

You can also define custom API types with their own headers and API payloads by defining `get_headers` and `get_api_payload` functions. You will also have to define an `extract_assistant_response` function to extract the assistants response from the API's JSON response. You can also define these functions for individual models. Here's an example defining `ollama` API type and adding `deepseek-coder:6.7b` to your options.

```lua
local util = require("coddit.util")

require("coddit").setup({
  api_types = {
    ["ollama"] = {
      endpoint = "http://localhost:11434/api/chat",
      get_headers = function(_)
        return { ["Content-Type"] = "application/json" }
      end,
      get_api_payload = function(prompt, model_opts, api_opts, module_opts)
        local system_prompt = model_opts.system_prompt or api_opts.system_prompt or module_opts.system_prompt
        local max_tokens = model_opts.max_tokens or api_opts.max_tokens or module_opts.max_tokens
        local stream = util.get_first_boolean(true, { model_opts.stream, api_opts.stream, module_opts.stream })

        return vim.fn.json_encode({
          model = model_opts.model,
          stream = stream,
          options = {
            num_predict = max_tokens,
          },
          messages = {
            { role = "system", content = system_prompt },
            { role = "user", content = prompt },
          },
        })
      end,
      extract_assistant_response = function(response)
        local decoded = vim.fn.json_decode(response)
        if decoded and decoded.message and decoded.message.content then
          return decoded.message.content
        end
        return nil
      end,
      extract_text_delta = function(response)
        local decoded = vim.fn.json_decode(response)
        if decoded and decoded.message and decoded.message.content then
          return decoded.message.content
        end
        return nil
      end,
      stream = true,
    },
  },
  models = {
    ["deepseek-coder"] = {
      model = "deepseek-coder:6.7b",
      api_type = "ollama",
    },
  },
  selected_model = "sonnet",
})
```

## Usage

### Lua API

```lua
local coddit = require("coddit")

-- Configure the module.
---@param opts? Opts Table of configuration options (optional)
coddit.setup({ ... })

-- Invoke the selected LLM endpoint.
-- If a visual block is selected, the snippet is communicated to the LLM,
-- else, the part of the buffer above and including the current cursor row
-- is communicated.
---@param toggle_show_diff? boolean Skip the diff if false, not if unspecified
coddit.call(toggle_show_diff)

-- Select the model to call when `coddit.call` is invoked. It updates the
-- `coddit.selected_model` attribute, which may also be specified during
-- the initial setup.
--
-- If invoked without the `model_name` argument, it displays a menu to pick
-- the model from.
---@param model_name? string
coddit.select_model(model_name)

-- Close the diff view if active.
coddit.close_diff_view()
```

### Recommended Mappings

These keymaps provide convenient access to coddit's main functions. Note that these keymaps are not set by default, you will have to add the following snippet to the `config` function in lazy.nvim config, or in another appropriate configuration file:

```lua
vim.keymap.set({ "n", "v" }, "<leader>aic", require("coddit").call, { desc = "Invoke coddit" })
vim.keymap.set({ "n", "v" }, "<leader>aid", require("coddit").close_diff_view, { desc = "Close coddit diffview" })

vim.keymap.set("n", "<leader>aim", function()
  require("coddit").select_model()
end, { desc = "Select model for coddit" })

vim.keymap.set("v", "<leader>aim", function()
  require("coddit").select_model(nil, function()
    vim.cmd("normal! gv")
    require("coddit").call()
  end)
end, { desc = "Select model for coddit and call" })

vim.keymap.set({ "n", "v" }, "<leader>aiC", function()
  require("coddit").call(true)
end, { desc = "Invoke coddit with toggled diff view" })
```

### Selecting the Model

The API and the keymap discussed above facilitate selecting your favourite LLM on the go.

![select_model](https://github.com/presindent/coddit.nvim/assets/115044400/f68ebca5-a271-428e-bc45-b75153ce8010)

## Roadmap

- [ ] Implement actions and CLI interaction.
- Tracking other enhancements and fixes as [issues](https://github.com/presindent/coddit.nvim/issues).

## Similar Plugins

This plugin is inspired by [llm.nvim](https://github.com/melbaldove/llm.nvim) by [melbaldove](https://github.com/melbaldove).

# coddit – with LLMs

coddit.nvim is a Neovim plugin to seamlessly harness coding capabilities of LLMs on your projects. Just select the code and ask away.

## Showcase

<table>
<tbody>
<tr>
<td><video src="https://github.com/presindent/coddit.nvim/assets/115044400/70372a6d-93dd-4db7-8f81-baffcd568701"/></td>
<td><video src="https://github.com/presindent/coddit.nvim/assets/115044400/521b9569-d632-4e06-9169-0e2a37a33727"/></td>
</tr>
</tbody>
</table>

## Setup

The following guide is specific to the [lazy.nvim](https://github.com/folke/lazy.nvim) plugin manager.

### Installation

Add the following table to your lazy.nvim configuration for a default setup using GPT-4o on OpenAI's API:

```lua
{
  "presindent/coddit.nvim",
  lazy = false,
  branch = "main",
}
```

### Customization

For custom model configurations, use this expanded setup:

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
    })
  end,
}
```

**Note:** coddit.nvim uses `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` environment variables by default for API keys. You may custom keys using `api_key` attribute in a model table during the setup.

You can further configure the headers and API payloads by defining `get_headers` and `get_api_payload` functions for a model. For example,

```lua
{
  ["llama"] = {
    get_headers = function()
      return {
        "content-type: application/json",
        ...
      }
    end,
    get_api_payload = function(system_prompt, user_prompt)
      return {
        model = "llama3",
        messages = [
          {
            role = "system",
            content = system_prompt,
          },
          {
            role = "user",
            content = user_prompt,
          },
        ],
      }
    end,
  }
}
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
---@param show_diff? boolean Skip the diff if false, not if unspecified
coddit.call(show_diff)

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

vim.keymap.set({ "n", "v" }, "<leader>aiC", function()
  require("coddit").call(false)
end, { desc = "Invoke coddit without diff view" })

vim.keymap.set({ "n" }, "<leader>aid", require("coddit").close_diff_view, { desc = "Close coddit diffview" })
vim.keymap.set({ "n" }, "<leader>aim", require("coddit").select_model, { desc = "Select model for coddit" })
```

### Selecting the Model

The API and the keymap discussed above facilitate selecting your favourite LLM on the go.

![select_model](https://github.com/presindent/coddit.nvim/assets/115044400/f68ebca5-a271-428e-bc45-b75153ce8010)

## Roadmap

- [ ] Implement actions and CLI interaction.
- [ ] Implement support for browser-based chatbots like ChatGPT.
- Tracking other enhancements and fixes as [issues](https://github.com/presindent/coddit.nvim/issues).

## Similar Plugins

This plugin is inspired by [llm.nvim](https://github.com/melbaldove/llm.nvim) by [melbaldove](https://github.com/melbaldove).

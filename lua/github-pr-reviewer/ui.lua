local M = {}

local review_groups = require("github-pr-reviewer.github").review_groups

local group_by_id = {}
for _, group in ipairs(review_groups) do
  group_by_id[group.id] = group
end

-- PR list columns: number, title, author, icon, review status. The title gets
-- whatever width the other columns leave over and is truncated to fit.
local COLUMN_SEPARATOR = "  "
local AUTHOR_MAX_WIDTH = 16
local TITLE_MIN_WIDTH = 20

local function show_icons()
  return require("github-pr-reviewer").config.show_icons
end

-- Icon and highlight for the PR's review group; "Other" splits out changes requested
local function pr_icon(pr)
  local group = group_by_id[pr.review_group]
  if not group then
    return "", nil
  end
  if group.id == "other" and pr.review and pr.review.changes_requested then
    return show_icons() and "✗" or "x", "DiagnosticError"
  end
  return show_icons() and group.icon or group.ascii, group.hl
end

-- Review status after the icon, as { text, hl } parts, e.g. "approved, review req, you reviewed"
local function pr_status_parts(pr)
  local review = pr.review or {}
  local parts = {}
  if review.approved then
    table.insert(parts, { "approved" })
  elseif review.changes_requested then
    table.insert(parts, { "changes req" })
  end
  if review.requested_from_me then
    table.insert(parts, { "review req", "DiagnosticInfo" })
  end
  if review.my_review == "APPROVED" then
    table.insert(parts, { "you approved", "DiagnosticInfo" })
  elseif review.my_review then
    table.insert(parts, { "you reviewed", "DiagnosticInfo" })
  end
  return parts
end

local function pr_status(pr)
  return table.concat(vim.tbl_map(function(part) return part[1] end, pr_status_parts(pr)), ", ")
end

-- Truncate `text` with an ellipsis and pad it to exactly `width` display cells
local function fit(text, width)
  if vim.fn.strdisplaywidth(text) > width then
    text = vim.fn.strcharpart(text, 0, width - 1)
    while vim.fn.strdisplaywidth(text) > width - 1 do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    text = text .. "…"
  end
  return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
end

-- Widths of every column but the title
local function pr_column_widths(prs)
  local widths = { number = 0, author = 0, icon = 0, status = 0 }
  for _, pr in ipairs(prs) do
    widths.number = math.max(widths.number, #("#" .. pr.number))
    widths.author = math.max(widths.author, vim.fn.strdisplaywidth("@" .. pr.author))
    widths.icon = math.max(widths.icon, vim.fn.strdisplaywidth((pr_icon(pr))))
    widths.status = math.max(widths.status, vim.fn.strdisplaywidth(pr_status(pr)))
  end
  widths.author = math.min(widths.author, AUTHOR_MAX_WIDTH)
  return widths
end

-- Title width that makes a whole row fit in `total` display cells
local function pr_title_width(widths, total)
  local fixed = widths.number + widths.author + widths.icon + widths.status + 4 * #COLUMN_SEPARATOR
  return math.max(TITLE_MIN_WIDTH, total - fixed)
end

local function format_pr_row(pr, widths, title_width)
  return vim.trim(table.concat({
    fit("#" .. pr.number, widths.number),
    fit(pr.title, title_width),
    fit("@" .. pr.author, widths.author),
    fit((pr_icon(pr)), widths.icon),
    pr_status(pr),
  }, COLUMN_SEPARATOR))
end

-- Text the pickers filter on: everything in the row plus the group label
local function pr_search_text(pr)
  local group = group_by_id[pr.review_group]
  return table.concat({ "#" .. pr.number, pr.title, "@" .. pr.author, group and group.label or "", pr_status(pr) }, " ")
end

-- Markdown shown in the picker's Description pane
local function format_pr_description(pr)
  local author = "@" .. pr.author
  if pr.author_name then
    author = string.format("%s (%s)", author, pr.author_name)
  end

  local lines = {
    "# " .. pr.title,
    "",
    "**Author:** " .. author,
    "**PR:** #" .. pr.number,
    string.format("**Branch:** `%s` → `%s`", pr.head_label or pr.head_branch, pr.base_branch),
  }

  local group = group_by_id[pr.review_group]
  if group then
    local status = pr_status(pr)
    table.insert(lines, string.format("**Review:** %s %s%s", (pr_icon(pr)), group.label,
      status ~= "" and (" (" .. status .. ")") or ""))
  end
  if pr.labels and #pr.labels > 0 then
    table.insert(lines, "**Labels:** " .. table.concat(pr.labels, ", "))
  end

  table.insert(lines, "")
  local body = vim.trim(((pr.body or ""):gsub("\r", "")))
  if body == "" then
    table.insert(lines, "_No description provided._")
  else
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end
  return lines
end

local function build_pr_list(prs, total_width)
  local widths = pr_column_widths(prs)
  local title_width = pr_title_width(widths, total_width)
  local items, pr_map = {}, {}

  for _, pr in ipairs(prs) do
    local display = format_pr_row(pr, widths, title_width)
    table.insert(items, display)
    pr_map[display] = pr
  end

  return items, pr_map
end

local function select_native(prs, callback)
  -- vim.ui.select has no preview pane, so the list can use most of the screen
  local items, pr_map = build_pr_list(prs, math.min(vim.o.columns - 8, 140))

  vim.ui.select(items, {
    prompt = "Select PR to review:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      callback(pr_map[choice])
    else
      callback(nil)
    end
  end)
end

local function select_fzf_lua(prs, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_native(prs, callback)
  end

  -- List on the left 60% of the window, minus borders, pointer and scrollbar
  local width, preview_width = 0.9, 0.4
  local items = build_pr_list(prs, math.floor(vim.o.columns * width * (1 - preview_width)) - 6)

  -- fzf previews by running a command, so write each description to a file named
  -- after the row's first field ("#123"). Neovim deletes its tempdir on exit.
  local preview_dir = vim.fn.tempname()
  vim.fn.mkdir(preview_dir, "p")
  local pr_by_number = {}
  for _, pr in ipairs(prs) do
    pr_by_number[pr.number] = pr
    vim.fn.writefile(format_pr_description(pr), preview_dir .. "/#" .. pr.number)
  end

  fzf.fzf_exec(items, {
    prompt = "Pull Requests> ",
    preview = "cat " .. vim.fn.shellescape(preview_dir) .. "/{1}",
    winopts = { width = width, height = 0.85, title = " Pull Requests " },
    fzf_opts = { ["--preview-window"] = string.format("right:%d%%:wrap", preview_width * 100) },
    actions = {
      ["default"] = function(selected)
        local number = selected and selected[1] and tonumber(selected[1]:match("^#(%d+)"))
        callback(number and pr_by_number[number] or nil)
      end,
    },
  })
end

local function select_telescope(prs, callback)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_native(prs, callback)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local previewers = require("telescope.previewers")
  local previewer_utils = require("telescope.previewers.utils")

  local widths = pr_column_widths(prs)
  local displayer = entry_display.create({
    separator = COLUMN_SEPARATOR,
    items = {
      { width = widths.number },
      -- Resolved against the results window width
      { width = function(_, columns) return pr_title_width(widths, columns) end },
      { width = widths.author },
      { width = widths.icon },
      { remaining = true },
    },
  })

  local function display_status(pr)
    local text, highlights = "", {}
    for i, part in ipairs(pr_status_parts(pr)) do
      if i > 1 then
        text = text .. ", "
      end
      if part[2] then
        table.insert(highlights, { { #text, #text + #part[1] }, part[2] })
      end
      text = text .. part[1]
    end
    return { text, function() return highlights end }
  end

  pickers
    .new({}, {
      prompt_title = "Pull Requests",
      results_title = "Results",
      sorting_strategy = "ascending",
      layout_strategy = "horizontal",
      layout_config = { prompt_position = "top", width = 0.9, height = 0.85, preview_width = 0.4 },
      finder = finders.new_table({
        results = prs,
        entry_maker = function(pr)
          local icon, icon_hl = pr_icon(pr)
          return {
            value = pr,
            display = function()
              return displayer({
                { "#" .. pr.number, "TelescopeResultsNumber" },
                pr.title,
                { "@" .. pr.author, "TelescopeResultsIdentifier" },
                { icon, icon_hl },
                display_status(pr),
              })
            end,
            ordinal = pr_search_text(pr),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Description",
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, format_pr_description(entry.value))
          vim.wo[self.state.winid].wrap = true
          vim.wo[self.state.winid].linebreak = true
          previewer_utils.highlighter(self.state.bufnr, "markdown")
        end,
      }),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            callback(selection.value)
          else
            callback(nil)
          end
        end)
        return true
      end,
    })
    :find()
end

-- Exposed for tests
M._format_pr_row = format_pr_row
M._pr_column_widths = pr_column_widths
M._pr_title_width = pr_title_width
M._format_pr_description = format_pr_description

function M.select_pr(prs, picker, callback)
  if picker == "fzf-lua" then
    select_fzf_lua(prs, callback)
  elseif picker == "telescope" then
    select_telescope(prs, callback)
  else
    select_native(prs, callback)
  end
end

local function format_review_request(pr, show_icons)
  local stats = string.format("+%d/-%d", pr.additions, pr.deletions)
  if show_icons then
    local viewed_icon = pr.viewed and "✓" or "○"
    return string.format(
      "%s #%d [%s] %s (%s) %s",
      viewed_icon,
      pr.number,
      pr.author,
      pr.title,
      pr.head_branch,
      stats
    )
  else
    local viewed_text = pr.viewed and "[viewed]" or "[new]"
    return string.format(
      "%s #%d [%s] %s (%s) %s",
      viewed_text,
      pr.number,
      pr.author,
      pr.title,
      pr.head_branch,
      stats
    )
  end
end

local function select_review_requests_native(prs, show_icons, on_select)
  local items = {}
  local pr_map = {}

  for _, pr in ipairs(prs) do
    local display = format_review_request(pr, show_icons)
    table.insert(items, display)
    pr_map[display] = pr
  end

  vim.ui.select(items, {
    prompt = "Select PR to review:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      on_select(pr_map[choice])
    end
  end)
end

local function select_review_requests_fzf(prs, show_icons, on_select)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_review_requests_native(prs, show_icons, on_select)
  end

  local items = {}
  local pr_map = {}

  for _, pr in ipairs(prs) do
    local display = format_review_request(pr, show_icons)
    table.insert(items, display)
    pr_map[display] = pr
  end

  fzf.fzf_exec(items, {
    prompt = "Review Requests> ",
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          on_select(pr_map[selected[1]])
        end
      end,
    },
  })
end

local function select_review_requests_telescope(prs, show_icons, on_select)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_review_requests_native(prs, show_icons, on_select)
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Review Requests",
      finder = finders.new_table({
        results = prs,
        entry_maker = function(pr)
          local display = format_review_request(pr, show_icons)
          return {
            value = pr,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            on_select(selection.value)
          end
        end)

        return true
      end,
    })
    :find()
end

function M.select_review_request(prs, picker, show_icons, on_select)
  if picker == "fzf-lua" then
    select_review_requests_fzf(prs, show_icons, on_select)
  elseif picker == "telescope" then
    select_review_requests_telescope(prs, show_icons, on_select)
  else
    select_review_requests_native(prs, show_icons, on_select)
  end
end

-- Pending comments picker functions
local function format_pending_comment(comment)
  local preview = comment.body:gsub("\n", " "):sub(1, 60)
  if #comment.body > 60 then
    preview = preview .. "..."
  end
  return string.format("[%s:%d] %s: %s", comment.path, comment.line, comment.user, preview)
end

local function select_pending_comments_native(comments, callback)
  if #comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(comments) do
    table.insert(items, format_pending_comment(comment))
  end

  vim.ui.select(items, {
    prompt = "Select pending comment:",
  }, function(_, idx)
    if idx then
      callback(comments[idx])
    end
  end)
end

local function select_pending_comments_fzf(comments, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_pending_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  local items = {}
  local comment_map = {}
  for _, comment in ipairs(comments) do
    local display = format_pending_comment(comment)
    table.insert(items, display)
    comment_map[display] = comment
  end

  fzf.fzf_exec(items, {
    prompt = "Pending Comments> ",
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          callback(comment_map[selected[1]])
        end
      end,
    },
  })
end

local function select_pending_comments_telescope(comments, callback)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_pending_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No pending comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Pending Comments",
      finder = finders.new_table({
        results = comments,
        entry_maker = function(comment)
          local display = format_pending_comment(comment)
          return {
            value = comment,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            callback(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.select_pending_comment(comments, picker, callback)
  if picker == "fzf-lua" then
    select_pending_comments_fzf(comments, callback)
  elseif picker == "telescope" then
    select_pending_comments_telescope(comments, callback)
  else
    select_pending_comments_native(comments, callback)
  end
end

-- All comments picker functions (with preview)
local function format_all_comment(comment)
  local status = comment.is_local and "[Pending]" or "[Posted]"
  return string.format("%s %s", status, comment.path)
end

local function select_all_comments_native(comments, callback)
  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(comments) do
    table.insert(items, format_all_comment(comment))
  end

  vim.ui.select(items, {
    prompt = "Select comment:",
  }, function(_, idx)
    if idx then
      callback(comments[idx])
    end
  end)
end

local function select_all_comments_fzf(comments, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_all_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  -- Create a temp directory for comment files
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  -- Write each comment to a separate file
  local temp_files = {}
  for i, comment in ipairs(comments) do
    local temp_file = temp_dir .. "/comment_" .. i .. ".txt"
    local status = comment.is_local and "[Pending]" or "[Posted]"
    local lines = {}
    table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    table.insert(lines, string.format("%s %s:%d", status, comment.path, comment.line))
    table.insert(lines, string.format("Author: %s", comment.user))
    if comment.created_at and comment.created_at ~= "" then
      table.insert(lines, string.format("Date: %s", comment.created_at))
    end
    table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    table.insert(lines, "")
    table.insert(lines, comment.body)

    vim.fn.writefile(lines, temp_file)
    table.insert(temp_files, temp_file)
  end

  -- Create entries with index
  local entries = {}
  for i, comment in ipairs(comments) do
    local status = comment.is_local and "[Pending]" or "[Posted]"
    local entry = string.format("%d|%s %s", i, status, comment.path)
    table.insert(entries, entry)
  end

  -- Create preview command
  local preview_cmd = string.format([[
    idx=$(echo {} | cut -d'|' -f1)
    if [ -z "$idx" ]; then echo "No preview"; exit 0; fi
    cat "%s/comment_${idx}.txt" 2>/dev/null || echo "Preview not available"
  ]], temp_dir)

  fzf.fzf_exec(entries, {
    prompt = "Comments> ",
    fzf_opts = {
      ["--delimiter"] = "|",
      ["--with-nth"] = "2..",
      ["--preview"] = preview_cmd,
      ["--preview-window"] = "right:60%:wrap",
    },
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          local idx = tonumber(selected[1]:match("^(%d+)"))
          if idx and comments[idx] then
            callback(comments[idx])
          end
        end
        -- Clean up temp files
        vim.fn.delete(temp_dir, "rf")
      end,
    },
  })
end

local function select_all_comments_telescope(comments, callback)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_all_comments_native(comments, callback)
  end

  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers
    .new({}, {
      prompt_title = "All Comments",
      finder = finders.new_table({
        results = comments,
        entry_maker = function(comment)
          local display = format_all_comment(comment)
          return {
            value = comment,
            display = display,
            ordinal = display,
            path = comment.path,
            lnum = comment.line,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Comment Preview",
        define_preview = function(self, entry)
          local comment = entry.value

          -- Show comment info
          local lines = {}
          local status = comment.is_local and "[Pending]" or "[Posted]"
          table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
          table.insert(lines, string.format("%s %s:%d", status, comment.path, comment.line))
          table.insert(lines, string.format("Author: %s", comment.user))
          if comment.created_at and comment.created_at ~= "" then
            table.insert(lines, string.format("Date: %s", comment.created_at))
          end
          table.insert(lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
          table.insert(lines, "")

          -- Add comment body
          for line in comment.body:gmatch("[^\r\n]+") do
            table.insert(lines, line)
          end

          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "markdown"
        end,
      }),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            callback(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.select_all_comments(comments, picker, callback)
  if picker == "fzf-lua" then
    select_all_comments_fzf(comments, callback)
  elseif picker == "telescope" then
    select_all_comments_telescope(comments, callback)
  else
    select_all_comments_native(comments, callback)
  end
end

-- Select global PR comment with fzf-lua
local function select_global_comments_fzf(comments, callback)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, using native picker", vim.log.levels.WARN)
    -- Fallback to vim.ui.select
    local items = {}
    for i, comment in ipairs(comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 80)
      if #comment.body > 80 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("#%d - %s: %s", i, comment.user, preview))
    end
    vim.ui.select(items, {
      prompt = "Global PR Comments:",
    }, function(_, idx)
      if idx then
        callback(comments[idx])
      end
    end)
    return
  end

  if #comments == 0 then
    vim.notify("No global comments", vim.log.levels.INFO)
    return
  end

  -- Create entries with index
  local entries = {}
  for i, comment in ipairs(comments) do
    local preview = comment.body:gsub("\n", " "):sub(1, 60)
    if #comment.body > 60 then
      preview = preview .. "..."
    end
    local entry = string.format("%d|%s: %s", i, comment.user, preview)
    table.insert(entries, entry)
  end

  fzf.fzf_exec(entries, {
    prompt = "Global Comments> ",
    fzf_opts = {
      ["--delimiter"] = "|",
      ["--with-nth"] = "2..",
      ["--preview"] = "echo {}  | cut -d'|' -f2-",
      ["--preview-window"] = "down:40%:wrap",
    },
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          local idx = tonumber(selected[1]:match("^(%d+)"))
          if idx and comments[idx] then
            callback(comments[idx], idx)
          end
        end
      end,
    },
  })
end

-- Select global PR comment with telescope
local function select_global_comments_telescope(comments, callback)
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope not installed, using native picker", vim.log.levels.WARN)
    -- Fallback to vim.ui.select
    local items = {}
    for i, comment in ipairs(comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 80)
      if #comment.body > 80 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("#%d - %s: %s", i, comment.user, preview))
    end
    vim.ui.select(items, {
      prompt = "Global PR Comments:",
    }, function(_, idx)
      if idx then
        callback(comments[idx])
      end
    end)
    return
  end

  if #comments == 0 then
    vim.notify("No global comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  -- Create entries
  local results = {}
  for i, comment in ipairs(comments) do
    table.insert(results, {
      index = i,
      user = comment.user,
      body = comment.body,
      created_at = comment.created_at,
      display = string.format("#%d - %s (%s)", i, comment.user, comment.created_at:sub(1, 10)),
    })
  end

  pickers.new({}, {
    prompt_title = "Global PR Comments",
    finder = finders.new_table({
      results = results,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.display,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Comment Body",
      define_preview = function(self, entry)
        local lines = vim.split(entry.value.body, "\n")
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          callback(comments[selection.value.index], selection.value.index)
        end
      end)
      return true
    end,
  }):find()
end

-- Main function to select global comments with specified picker
function M.select_global_comments(comments, picker, callback)
  if picker == "fzf-lua" or picker == "fzf" then
    select_global_comments_fzf(comments, callback)
  elseif picker == "telescope" then
    select_global_comments_telescope(comments, callback)
  else
    -- Use vim.ui.select as fallback
    local items = {}
    for i, comment in ipairs(comments) do
      local preview = comment.body:gsub("\n", " "):sub(1, 80)
      if #comment.body > 80 then
        preview = preview .. "..."
      end
      table.insert(items, string.format("#%d - %s: %s", i, comment.user, preview))
    end
    vim.ui.select(items, {
      prompt = "Global PR Comments:",
    }, function(_, idx)
      if idx then
        callback(comments[idx], idx)
      end
    end)
  end
end

-- Select emoji reaction
function M.select_emoji_reaction(callback)
  local reactions = {
    { emoji = "👍", label = "👍 Thumbs Up", content = "+1" },
    { emoji = "👎", label = "👎 Thumbs Down", content = "-1" },
    { emoji = "😄", label = "😄 Laugh", content = "laugh" },
    { emoji = "🎉", label = "🎉 Hooray", content = "hooray" },
    { emoji = "😕", label = "😕 Confused", content = "confused" },
    { emoji = "❤️", label = "❤️ Heart", content = "heart" },
    { emoji = "🚀", label = "🚀 Rocket", content = "rocket" },
    { emoji = "👀", label = "👀 Eyes", content = "eyes" },
  }

  local items = {}
  local reaction_map = {}
  for _, reaction in ipairs(reactions) do
    table.insert(items, reaction.label)
    reaction_map[reaction.label] = reaction.content
  end

  vim.ui.select(items, {
    prompt = "Select emoji reaction:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if choice then
      callback(reaction_map[choice])
    else
      callback(nil)
    end
  end)
end

return M

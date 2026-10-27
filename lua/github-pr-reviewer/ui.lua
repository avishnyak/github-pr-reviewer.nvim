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

-- All comments picker: comments grouped into review threads under file headings.
-- Telescope can collapse and expand threads; fzf-lua and native list them expanded.

local THREAD_STATES = {
  unresolved = { icon = "●", ascii = "o", label = "Unresolved", hl = "DiagnosticWarn" },
  resolved = { icon = "✓", ascii = "+", label = "Resolved", hl = "DiagnosticOk" },
  outdated = { icon = "◌", ascii = "~", label = "Outdated", hl = "Comment" },
  pending = { icon = "✎", ascii = "*", label = "Pending", hl = "DiagnosticInfo" },
}
local THREAD_AUTHOR_MAX_WIDTH = 16
local THREAD_BODY_MIN_WIDTH = 20

local function thread_icons()
  local icons = show_icons()
  return {
    expanded = icons and "▼" or "-",
    collapsed = icons and "▶" or "+",
    reply = icons and "└" or "\\",
    bar = icons and "▌" or "|",
  }
end

local function thread_state_icon(thread)
  local state = THREAD_STATES[thread.state]
  return show_icons() and state.icon or state.ascii, state.hl
end

-- Group comments into threads by in_reply_to_id, sorted by path, then line.
-- `states` maps a thread's first comment id to { resolved, outdated }; nil when unknown.
local function build_comment_threads(comments, states)
  local by_id = {}
  for _, comment in ipairs(comments) do
    if comment.id then
      by_id[comment.id] = comment
    end
  end

  local function root_of(comment)
    local seen = {}
    while comment.in_reply_to_id and by_id[comment.in_reply_to_id] and not seen[comment] do
      seen[comment] = true
      comment = by_id[comment.in_reply_to_id]
    end
    return comment
  end

  local threads, by_root = {}, {}
  for _, comment in ipairs(comments) do
    local root = root_of(comment)
    local thread = by_root[root]
    if not thread then
      local known = (not root.is_local and states and states[root.id]) or {}
      thread = {
        root = root,
        replies = {},
        path = root.path,
        line = root.line,
        state = root.is_local and "pending" or known.resolved and "resolved" or known.outdated and "outdated"
          or "unresolved",
      }
      by_root[root] = thread
      table.insert(threads, thread)
    end
    if comment ~= root then
      table.insert(thread.replies, comment)
    end
  end

  local function created(comment)
    return comment.created_at or ""
  end
  for _, thread in ipairs(threads) do
    table.sort(thread.replies, function(a, b) return created(a) < created(b) end)
  end
  table.sort(threads, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.line ~= b.line then
      return (a.line or 0) < (b.line or 0)
    end
    return created(a.root) < created(b.root)
  end)
  return threads
end

-- Resolved and outdated threads start collapsed
local function default_collapsed(threads)
  local collapsed = {}
  for _, thread in ipairs(threads) do
    collapsed[thread] = thread.state == "resolved" or thread.state == "outdated"
  end
  return collapsed
end

local function comment_search_text(comment)
  return (comment.user or "") .. " " .. (comment.body or "")
end

local function thread_search_text(thread)
  local parts = { thread.path .. ":" .. tostring(thread.line), comment_search_text(thread.root) }
  for _, reply in ipairs(thread.replies) do
    table.insert(parts, comment_search_text(reply))
  end
  return table.concat(parts, " ")
end

-- Picker rows: a file heading, then each thread and, when expanded, its replies.
-- Thread and file rows search their replies too, so a match keeps its context.
local function comment_thread_rows(threads, collapsed)
  local rows, file_row = {}, nil
  for _, thread in ipairs(threads) do
    if not file_row or file_row.path ~= thread.path then
      file_row = { kind = "file", path = thread.path, threads = {}, search = thread.path }
      table.insert(rows, file_row)
    end
    local search = thread_search_text(thread)
    table.insert(file_row.threads, thread)
    file_row.search = file_row.search .. " " .. search
    table.insert(rows, { kind = "thread", thread = thread, comment = thread.root, search = search })
    if not collapsed[thread] then
      for _, reply in ipairs(thread.replies) do
        table.insert(rows, {
          kind = "reply",
          thread = thread,
          comment = reply,
          search = thread.path .. " " .. comment_search_text(reply),
        })
      end
    end
  end
  return rows
end

-- Widths of every thread row column but the body
local function comment_thread_widths(threads)
  local widths = { line = 0, author = 0, count = 0 }
  for _, thread in ipairs(threads) do
    widths.line = math.max(widths.line, #(":" .. tostring(thread.line or "")))
    for _, comment in ipairs({ thread.root, unpack(thread.replies) }) do
      widths.author = math.max(widths.author, vim.fn.strdisplaywidth(comment.user or ""))
    end
    if #thread.replies > 0 then
      widths.count = math.max(widths.count, #("+" .. #thread.replies))
    end
  end
  widths.author = math.min(widths.author, THREAD_AUTHOR_MAX_WIDTH)
  return widths
end

-- Body width that makes a thread row fit in `total` display cells
local function comment_thread_body_width(widths, total)
  -- fold, state, line and author columns, each followed by a separator
  local fixed = 1 + 1 + widths.line + widths.author + 4
  if widths.count > 0 then
    fixed = fixed + widths.count + 1
  end
  return math.max(THREAD_BODY_MIN_WIDTH, total - fixed)
end

local function comment_summary(comment)
  return vim.trim(((comment.body or ""):gsub("%s+", " ")))
end

-- Cells of a thread or reply row as { text, hl } in column order
local function comment_thread_cells(row, collapsed)
  local icons = thread_icons()
  local thread, comment = row.thread, row.comment
  local count = ""
  if row.kind == "reply" then
    return {
      { " " }, { " " }, { icons.reply, "Comment" },
      { comment.user or "", "TelescopeResultsIdentifier" }, { comment_summary(comment) }, { count },
    }
  end
  local fold = #thread.replies == 0 and " " or (collapsed[thread] and icons.collapsed or icons.expanded)
  if collapsed[thread] and #thread.replies > 0 then
    count = "+" .. #thread.replies
  end
  local state_icon, state_hl = thread_state_icon(thread)
  return {
    { fold, "Comment" }, { state_icon, state_hl }, { ":" .. tostring(thread.line or ""), "TelescopeResultsLineNr" },
    { comment.user or "", "TelescopeResultsIdentifier" }, { comment_summary(comment) }, { count, "Comment" },
  }
end

-- Plain-text row for pickers without per-column highlights
local function format_comment_thread_row(row, collapsed, widths, body_width)
  if row.kind == "file" then
    return row.path
  end
  local cells = comment_thread_cells(row, collapsed)
  local columns = {
    fit(cells[1][1], 1), fit(cells[2][1], 1), fit(cells[3][1], widths.line),
    fit(cells[4][1], widths.author), fit(cells[5][1], body_width),
  }
  if widths.count > 0 then
    table.insert(columns, string.rep(" ", widths.count - #cells[6][1]) .. cells[6][1])
  end
  return (table.concat(columns, " "):gsub("%s+$", ""))
end

local function format_comment_date(created_at)
  if not created_at or created_at == "" then
    return nil
  end
  return (created_at:gsub("^(%d+%-%d+%-%d+)T(%d+:%d+).*$", "%1 %2"))
end

-- Preview of a row's thread (or of every thread in a file heading's file).
-- Returns lines, highlights as { line, col_start, col_end, hl } (0-based), and the
-- 1-based line to scroll to.
local function format_comment_thread_preview(row)
  local icons = thread_icons()
  local lines, highlights, focus = {}, {}, 1
  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      table.insert(highlights, { #lines - 1, 0, -1, hl })
    end
  end

  if row.kind == "file" then
    local count = 0
    for _, thread in ipairs(row.threads) do
      count = count + 1 + #thread.replies
    end
    add(row.path, "Directory")
    add(string.format("%d threads · %d comments", #row.threads, count), "Comment")
    add(string.rep("─", 50), "Comment")
    for _, thread in ipairs(row.threads) do
      local icon, hl = thread_state_icon(thread)
      add(string.format("%s :%s  %s  %s", icon, tostring(thread.line or ""), thread.root.user or "",
        comment_summary(thread.root)))
      table.insert(highlights, { #lines - 1, 0, #icon, hl })
    end
    return lines, highlights, focus
  end

  local thread = row.thread
  local state = THREAD_STATES[thread.state]
  local icon, icon_hl = thread_state_icon(thread)
  local count = 1 + #thread.replies
  add(thread.path .. ":" .. tostring(thread.line or ""), "Directory")
  add(string.format("%s %s · %d comment%s", icon, state.label, count, count == 1 and "" or "s"))
  table.insert(highlights, { #lines - 1, 0, #icon, icon_hl })
  add(string.rep("─", 50), "Comment")

  for _, comment in ipairs({ thread.root, unpack(thread.replies) }) do
    local selected = comment == row.comment
    local prefix = selected and (icons.bar .. " ") or "  "
    if selected then
      focus = #lines + 1
    end
    local date = format_comment_date(comment.created_at)
    add(prefix .. (comment.user or "") .. (date and (" · " .. date) or ""))
    table.insert(highlights, { #lines - 1, #prefix, #prefix + #(comment.user or ""), "Title" })
    if date then
      table.insert(highlights, { #lines - 1, #prefix + #(comment.user or ""), -1, "Comment" })
    end
    for _, body_line in ipairs(vim.split(((comment.body or ""):gsub("\r", "")), "\n", { plain = true })) do
      add(prefix .. body_line)
    end
    if selected then
      for line = focus, #lines do
        table.insert(highlights, { line - 1, 0, #prefix, "DiagnosticInfo" })
      end
    end
    add("")
  end
  return lines, highlights, focus
end

-- The comment <CR> jumps to: a file heading picks its first thread
local function comment_thread_target(row)
  if row.kind == "file" then
    return row.threads[1].root
  end
  return row.comment
end

local function select_all_comments_native(comments, callback, states)
  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local threads = build_comment_threads(comments, states)
  local rows = comment_thread_rows(threads, {})
  local widths = comment_thread_widths(threads)
  local body_width = comment_thread_body_width(widths, math.min(vim.o.columns - 8, 140))

  vim.ui.select(rows, {
    prompt = "Select comment:",
    format_item = function(row)
      return format_comment_thread_row(row, {}, widths, body_width)
    end,
  }, function(row)
    if row then
      callback(comment_thread_target(row))
    end
  end)
end

local function select_all_comments_fzf(comments, callback, states)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("fzf-lua not installed, falling back to native picker", vim.log.levels.WARN)
    return select_all_comments_native(comments, callback, states)
  end

  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local threads = build_comment_threads(comments, states)
  local rows = comment_thread_rows(threads, {})
  local widths = comment_thread_widths(threads)
  local width, preview_width = 0.9, 0.45
  local body_width = comment_thread_body_width(widths, math.floor(vim.o.columns * width * (1 - preview_width)) - 6)

  -- fzf previews by running a command, so write each row's thread to a numbered file.
  -- Neovim deletes its tempdir on exit.
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local entries = {}
  for i, row in ipairs(rows) do
    vim.fn.writefile((format_comment_thread_preview(row)), temp_dir .. "/" .. i)
    table.insert(entries, i .. "|" .. format_comment_thread_row(row, {}, widths, body_width))
  end

  fzf.fzf_exec(entries, {
    prompt = "Comments> ",
    winopts = { width = width, height = 0.85, title = " All Comments " },
    fzf_opts = {
      ["--delimiter"] = "|",
      ["--with-nth"] = "2..",
      ["--preview"] = "cat " .. vim.fn.shellescape(temp_dir) .. "/{1}",
      ["--preview-window"] = string.format("right:%d%%:wrap", preview_width * 100),
    },
    actions = {
      ["default"] = function(selected)
        local idx = selected and selected[1] and tonumber(selected[1]:match("^(%d+)|"))
        if idx and rows[idx] then
          callback(comment_thread_target(rows[idx]))
        end
      end,
    },
  })
end

local function select_all_comments_telescope(comments, callback, states)
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("telescope not installed, falling back to native picker", vim.log.levels.WARN)
    return select_all_comments_native(comments, callback, states)
  end

  if #comments == 0 then
    vim.notify("No comments", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local sorters = require("telescope.sorters")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local previewers = require("telescope.previewers")

  local threads = build_comment_threads(comments, states)
  local collapsed = default_collapsed(threads)
  local widths = comment_thread_widths(threads)

  local columns = {
    { width = 1 },
    { width = 1 },
    { width = widths.line },
    { width = widths.author },
    -- Resolved against the results window width
    { width = function(_, cols) return comment_thread_body_width(widths, cols) end },
  }
  if widths.count > 0 then
    table.insert(columns, { width = widths.count, right_justify = true })
  end
  local displayer = entry_display.create({ separator = " ", items = columns })

  local function make_finder()
    return finders.new_table({
      results = comment_thread_rows(threads, collapsed),
      entry_maker = function(row)
        return {
          value = row,
          ordinal = row.search,
          display = function()
            if row.kind == "file" then
              return row.path, { { { 0, #row.path }, "Directory" } }
            end
            local cells = comment_thread_cells(row, collapsed)
            return displayer({ cells[1], cells[2], cells[3], cells[4], cells[5][1], cells[6] })
          end,
        }
      end,
    })
  end

  -- Filter on every word of the prompt but keep the tree order
  local sorter = sorters.Sorter:new({
    scoring_function = function(_, prompt, ordinal, entry)
      local haystack = ordinal:lower()
      for word in prompt:lower():gmatch("%S+") do
        if not haystack:find(word, 1, true) then
          return -1
        end
      end
      return entry.index
    end,
  })

  local comment_count = 0
  for _, thread in ipairs(threads) do
    comment_count = comment_count + 1 + #thread.replies
  end

  -- Row to select once a refresh finishes, matched by thread or file path
  local reselect

  pickers
    .new({}, {
      prompt_title = string.format("All Comments · %d threads · %d comments", #threads, comment_count),
      results_title = "<C-e> expand/collapse · <C-a> all · <C-j>/<C-k> next/prev thread · <CR> jump",
      sorting_strategy = "ascending",
      layout_strategy = "horizontal",
      layout_config = { prompt_position = "top", width = 0.9, height = 0.85, preview_width = 0.45 },
      -- Start on the first thread rather than its file heading
      default_selection_index = 2,
      finder = make_finder(),
      sorter = sorter,
      previewer = previewers.new_buffer_previewer({
        title = "Thread",
        define_preview = function(self, entry)
          local lines, highlights, focus = format_comment_thread_preview(entry.value)
          local bufnr, winid = self.state.bufnr, self.state.winid
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          local ns = vim.api.nvim_create_namespace("pr_review_thread_preview")
          for _, hl in ipairs(highlights) do
            vim.api.nvim_buf_add_highlight(bufnr, ns, hl[4], hl[1], hl[2], hl[3])
          end
          vim.wo[winid].wrap = true
          vim.wo[winid].linebreak = true
          vim.wo[winid].breakindent = true
          pcall(vim.api.nvim_win_set_cursor, winid, { focus, 0 })
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        local picker = action_state.get_current_picker(prompt_bufnr)

        picker:register_completion_callback(function(p)
          if not reselect then
            return
          end
          local target = reselect
          reselect = nil
          local index = 0
          for entry in p.manager:iter() do
            index = index + 1
            local row = entry.value
            if (target.thread and row.kind == "thread" and row.thread == target.thread)
                or (target.path and row.kind == "file" and row.path == target.path) then
              p:set_selection(p:get_row(index))
              return
            end
          end
        end)

        local function selected_row()
          local selection = action_state.get_selected_entry()
          return selection and selection.value
        end

        local function refresh(row)
          reselect = row and (row.thread and { thread = row.thread } or { path = row.path })
          picker:refresh(make_finder(), { reset_prompt = false })
        end

        local function toggle_thread()
          local row = selected_row()
          if row and row.thread and #row.thread.replies > 0 then
            collapsed[row.thread] = not collapsed[row.thread]
            refresh(row)
          end
        end

        local function toggle_all()
          local any_expanded = false
          for _, thread in ipairs(threads) do
            if #thread.replies > 0 and not collapsed[thread] then
              any_expanded = true
            end
          end
          for _, thread in ipairs(threads) do
            collapsed[thread] = any_expanded
          end
          refresh(selected_row())
        end

        local function jump_thread(step)
          local current = selected_row()
          local entries = {}
          for entry in picker.manager:iter() do
            table.insert(entries, entry.value)
          end
          local from = 0
          for i, row in ipairs(entries) do
            if row == current then
              from = i
            end
          end
          local i = from + step
          while i >= 1 and i <= #entries do
            if entries[i].kind == "thread" then
              picker:set_selection(picker:get_row(i))
              return
            end
            i = i + step
          end
        end

        map({ "i", "n" }, "<C-e>", toggle_thread)
        map({ "i", "n" }, "<C-a>", toggle_all)
        map({ "i", "n" }, "<C-j>", function() jump_thread(1) end)
        map({ "i", "n" }, "<C-k>", function() jump_thread(-1) end)

        actions.select_default:replace(function()
          local row = selected_row()
          actions.close(prompt_bufnr)
          if row then
            callback(comment_thread_target(row))
          end
        end)
        return true
      end,
    })
    :find()
end

function M.select_all_comments(comments, picker, callback, thread_states)
  if picker == "fzf-lua" then
    select_all_comments_fzf(comments, callback, thread_states)
  elseif picker == "telescope" then
    select_all_comments_telescope(comments, callback, thread_states)
  else
    select_all_comments_native(comments, callback, thread_states)
  end
end

-- Exposed for tests
M._build_comment_threads = build_comment_threads
M._comment_thread_rows = comment_thread_rows
M._default_collapsed = default_collapsed
M._comment_thread_widths = comment_thread_widths
M._format_comment_thread_row = format_comment_thread_row
M._format_comment_thread_preview = format_comment_thread_preview

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

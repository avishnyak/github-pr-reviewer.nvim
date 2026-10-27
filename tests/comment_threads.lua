-- Run with: nvim --headless -u NONE -c 'set rtp+=.' -l tests/comment_threads.lua
require("github-pr-reviewer").setup()
local ui = require("github-pr-reviewer.ui")

local function comment(id, path, line, user, body, created_at, reply_to)
  return { id = id, path = path, line = line, user = user, body = body, created_at = created_at, in_reply_to_id = reply_to }
end

local comments = {
  comment(3, "b.rb", 5, "carol", "Second reply", "2026-10-27T18:30:00Z", 1),
  comment(1, "b.rb", 5, "alice", "Root\nwith two lines", "2026-10-27T18:00:00Z"),
  comment(2, "b.rb", 5, "bob", "First reply", "2026-10-27T18:20:00Z", 1),
  comment(4, "a.rb", 9, "dave", "Resolved root", "2026-10-26T10:00:00Z"),
  comment(5, "a.rb", 9, "erin", "Resolved reply", "2026-10-26T11:00:00Z", 4),
  comment(6, "b.rb", 1, "frank", "Outdated", "2026-10-25T10:00:00Z"),
  -- Reply whose parent isn't listed becomes its own thread
  comment(7, "b.rb", 7, "gina", "Orphan", "2026-10-25T10:00:00Z", 99),
  { id = "local_1", path = "a.rb", line = 2, user = "You (PENDING)", body = "Pending", is_local = true },
}
local states = { [4] = { resolved = true }, [6] = { outdated = true }, [1] = { resolved = false } }

-- Threads sort by path then line; replies by date
local threads = ui._build_comment_threads(comments, states)
local summary = vim.tbl_map(function(t)
  return string.format("%s:%d:%s:%d", t.path, t.line, t.state, #t.replies)
end, threads)
assert(table.concat(summary, " ") == "a.rb:2:pending:0 a.rb:9:resolved:1 b.rb:1:outdated:0 b.rb:5:unresolved:2 b.rb:7:unresolved:0",
  table.concat(summary, " "))
assert(threads[4].replies[1].user == "bob" and threads[4].replies[2].user == "carol")

-- Unknown states (fetch failed) leave every posted thread unresolved
assert(ui._build_comment_threads(comments, nil)[2].state == "unresolved")

-- Resolved and outdated threads start collapsed; rows are file, thread, replies
local collapsed = ui._default_collapsed(threads)
assert(collapsed[threads[2]] and collapsed[threads[3]] and not collapsed[threads[4]])
local rows = ui._comment_thread_rows(threads, collapsed)
local kinds = vim.tbl_map(function(r) return r.kind .. ":" .. (r.comment and r.comment.user or r.path) end, rows)
assert(table.concat(kinds, " ") ==
  "file:a.rb thread:You (PENDING) thread:dave file:b.rb thread:frank thread:alice reply:bob reply:carol thread:gina",
  table.concat(kinds, " "))
-- A collapsed thread still matches its replies' text; file headings match everything in the file
assert(rows[3].search:find("Resolved reply", 1, true))
assert(rows[4].search:find("Second reply", 1, true))

-- Expanding shows the replies
collapsed[threads[2]] = false
assert(#ui._comment_thread_rows(threads, collapsed) == #rows + 1)
collapsed[threads[2]] = true

-- Rows: fold, state, line, author, body, hidden reply count
local widths = ui._comment_thread_widths(threads)
local function row_text(i) return ui._format_comment_thread_row(rows[i], collapsed, widths, 30) end
assert(row_text(1) == "a.rb")
assert(row_text(3) == "▶ ✓ :9 dave          Resolved root                  +1", row_text(3))
assert(row_text(6) == "▼ ● :5 alice         Root with two lines", row_text(6))
assert(row_text(7) == "    └  bob           First reply", row_text(7))
assert(row_text(2):find("^  ✎ :2 You %(PENDING%)"), row_text(2))

-- Preview shows the whole thread and marks the selected comment
local lines, _, focus = ui._format_comment_thread_preview(rows[7])
assert(lines[1] == "b.rb:5" and lines[2] == "● Unresolved · 3 comments", lines[2])
assert(lines[focus] == "▌ bob · 2026-10-27 18:20", lines[focus])
assert(lines[focus + 1] == "▌ First reply")
assert(vim.tbl_contains(lines, "  alice · 2026-10-27 18:00"))
assert(vim.tbl_contains(lines, "  with two lines"))
local file_lines = ui._format_comment_thread_preview(rows[4])
assert(file_lines[2] == "3 threads · 5 comments", file_lines[2])

print("comment threads test passed")

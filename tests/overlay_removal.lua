-- Run with: nvim --headless -u NONE -c 'set rtp+=.' -l tests/overlay_removal.lua
local reviewer = require("github-pr-reviewer")
reviewer.setup()

assert(vim.fn.exists(":PRReview") == 2, "regular review command is missing")
assert(vim.fn.exists(":PRReviewCleanup") == 2, "review cleanup command is missing")
assert(vim.fn.exists(":PRCommentOverlay") == 0, "overlay command still exists")
assert(vim.fn.exists(":PRReanchorCommentOverlay") == 0, "overlay reanchor command still exists")
assert(reviewer.start_comment_overlay == nil, "overlay API still exists")
assert(type(reviewer._inline_diff_request_ids) == "table", "inline-diff race guard is missing")

local github = require("github-pr-reviewer.github")
local original_jobstart = vim.fn.jobstart
local command
vim.fn.jobstart = function(cmd, opts)
  command = cmd
  opts.on_stdout(1, { "" })
  return 1
end

local completed = false
github.fetch_pr_comments(987654321, function(comments, err)
  assert(err == nil and #comments == 0)
  completed = true
end)
assert(vim.wait(1000, function() return completed end), "comment fetch did not finish")
assert(command:find("/pulls/987654321/comments --paginate", 1, true), "pagination was removed")
vim.fn.jobstart = original_jobstart
print("overlay removal smoke test passed")

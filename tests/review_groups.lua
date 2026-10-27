-- Run with: nvim --headless -u NONE -c 'set rtp+=.' -l tests/review_groups.lua
require("github-pr-reviewer").setup()
local github = require("github-pr-reviewer.github")

local function review(login, state)
  return { author = { login = login }, state = state }
end

local function pr(fields)
  return vim.tbl_extend("force", { author = { login = "owner" }, latestReviews = {}, reviewRequests = {} }, fields)
end

local function group(fields)
  return github.classify_review_group(pr(fields), "me")
end

-- No reviews yet; bot and self reviews don't count
assert(group({ reviewDecision = "REVIEW_REQUIRED" }) == "review_required")
assert(group({
  reviewDecision = "REVIEW_REQUIRED",
  latestReviews = {
    review("copilot-pull-request-reviewer", "COMMENTED"),
    review("dependabot[bot]", "COMMENTED"),
    review("owner", "COMMENTED"),
  },
}) == "review_required")

-- Re-requested from me after I reviewed, even if someone else approved
assert(group({
  reviewDecision = "APPROVED",
  reviewRequests = { { __typename = "User", login = "me" } },
  latestReviews = { review("me", "CHANGES_REQUESTED"), review("other", "APPROVED") },
}) == "rereview")

-- A first-time request is not a re-review
assert(group({
  reviewDecision = "REVIEW_REQUIRED",
  reviewRequests = { { __typename = "User", login = "me" } },
}) == "review_required")

-- Approved, including repos where reviews aren't required (empty decision)
assert(group({ reviewDecision = "APPROVED", latestReviews = { review("other", "APPROVED") } }) == "approved")
assert(group({ reviewDecision = "", latestReviews = { review("other", "APPROVED") } }) == "approved")
assert(group({
  reviewDecision = "",
  latestReviews = { review("other", "APPROVED"), review("third", "CHANGES_REQUESTED") },
}) == "other")

-- Reviewed but not approved
assert(group({ reviewDecision = "CHANGES_REQUESTED", latestReviews = { review("other", "CHANGES_REQUESTED") } }) == "other")
assert(group({ reviewDecision = "REVIEW_REQUIRED", latestReviews = { review("other", "COMMENTED") } }) == "other")

-- Status details for the picker's status column
local summary = github.review_summary(pr({
  reviewDecision = "CHANGES_REQUESTED",
  latestReviews = { review("me", "COMMENTED"), review("other", "CHANGES_REQUESTED") },
}), "me")
assert(summary.group == "other" and summary.changes_requested and not summary.approved)
assert(summary.my_review == "COMMENTED" and not summary.requested_from_me)

-- A team request (passed in from the review-requested:@me search) counts as requested from me
assert(github.classify_review_group(pr({ latestReviews = { review("me", "COMMENTED") } }), "me", true) == "rereview")
assert(github.classify_review_group(pr({
  reviewRequests = { { login = "me" } }, latestReviews = { review("me", "COMMENTED") },
}), "me", false) == "other")

-- list_open_prs passes the search query and sorts by group, keeping gh's order within a group
local original_system = vim.fn.system
local command, requested_command
vim.fn.system = function(cmd)
  if cmd:find("gh api user", 1, true) then
    return "me\n"
  end
  if cmd:find("review-requested:@me", 1, true) then
    requested_command = cmd
    return vim.fn.json_encode({ { number = 2 }, { number = 1 } })
  end
  command = cmd
  return vim.fn.json_encode({
    pr({ number = 5, title = "a", reviewDecision = "APPROVED" }),
    pr({ number = 4, title = "b", reviewDecision = "REVIEW_REQUIRED", latestReviews = { review("x", "COMMENTED") } }),
    pr({ number = 3, title = "c", reviewDecision = "REVIEW_REQUIRED" }),
    pr({ number = 2, title = "d", reviewDecision = "REVIEW_REQUIRED",
      reviewRequests = { { login = "me" } }, latestReviews = { review("me", "COMMENTED") } }),
    pr({ number = 1, title = "e", reviewDecision = "REVIEW_REQUIRED" }),
  })
end
local config = require("github-pr-reviewer").config
config.pr_search = "draft:false base:dev"
local prs = assert(github.list_open_prs())

-- Own PRs are excluded in the query by default
assert(command:find("--search 'draft:false base:dev -author:@me'", 1, true), command)
assert(requested_command:find("--search 'draft:false base:dev -author:@me review-requested:@me'", 1, true),
  requested_command)
config.exclude_own_prs = false
github.list_open_prs()
assert(command:find("--search 'draft:false base:dev' ", 1, true), command)
config.pr_search = nil
github.list_open_prs()
assert(not command:find("--search", 1, true), command)
config.exclude_own_prs = true
github.list_open_prs()
assert(command:find("--search '-author:@me'", 1, true), command)
vim.fn.system = original_system

local order = vim.tbl_map(function(p) return p.number .. ":" .. p.review_group end, prs)
assert(table.concat(order, " ") == "3:review_required 1:review_required 2:rereview 4:other 5:approved",
  table.concat(order, " "))
local requested = vim.tbl_map(function(p) return tostring(p.review.requested_from_me) end, prs)
assert(table.concat(requested, " ") == "false true true false false", table.concat(requested, " "))

-- Picker rows: number, title truncated to fit, author, group icon, review status
local ui = require("github-pr-reviewer.ui")
local rows = {
  { number = 7, title = "feat: a title that is much too long to fit", author = "someone",
    review_group = "approved", review = { approved = true, requested_from_me = true, my_review = "APPROVED" } },
  { number = 1234, title = "fix: short", author = "a-very-long-author-name",
    review_group = "other", review = { changes_requested = true } },
  { number = 8, title = "chore: new", author = "x", review_group = "review_required", review = {} },
}
local widths = ui._pr_column_widths(rows)
local title_width = ui._pr_title_width(widths, 100)
local formatted_rows = vim.tbl_map(function(r) return ui._format_pr_row(r, widths, title_width) end, rows)
assert(title_width == 100 - (5 + 16 + 1 + 34 + 8), title_width)
assert(formatted_rows[1] == "#7     feat: a title that is much too long…  @someone          ✓  approved, review req, you approved",
  formatted_rows[1])
assert(formatted_rows[2]:find("^#1234  fix: short%s+@a%-very%-long%-au…  ✗  changes req$"), formatted_rows[2])
assert(formatted_rows[3]:find("@x%s+○$"), formatted_rows[3])
assert(ui._format_pr_row(rows[1], widths, 20):find("feat: a title that …  @someone", 1, true))

local description = ui._format_pr_description(vim.tbl_extend("force", rows[1], {
  author_name = "Some One", head_branch = "feat", base_branch = "dev", labels = { "bug" }, body = "Line 1\r\nLine 2",
}))
assert(description[1] == "# feat: a title that is much too long to fit")
assert(vim.tbl_contains(description, "**Author:** @someone (Some One)"))
assert(vim.tbl_contains(description, "**Review:** ✓ Approved (approved, review req, you approved)"))
assert(vim.tbl_contains(description, "**Labels:** bug"))
assert(description[#description - 1] == "Line 1" and description[#description] == "Line 2")
assert(ui._format_pr_description(rows[3])[#ui._format_pr_description(rows[3])] == "_No description provided._")
print("review groups test passed")

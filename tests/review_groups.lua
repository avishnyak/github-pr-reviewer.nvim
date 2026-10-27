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

-- list_open_prs passes the search query and sorts by group, keeping gh's order within a group
local original_system = vim.fn.system
local command
vim.fn.system = function(cmd)
  if cmd:find("gh api user", 1, true) then
    return "me\n"
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
require("github-pr-reviewer").config.pr_search = "draft:false base:dev"
local prs = assert(github.list_open_prs())
vim.fn.system = original_system

assert(command:find("--search 'draft:false base:dev'", 1, true), command)
local order = vim.tbl_map(function(p) return p.number .. ":" .. p.review_group end, prs)
assert(table.concat(order, " ") == "3:review_required 1:review_required 2:rereview 4:other 5:approved",
  table.concat(order, " "))
print("review groups test passed")

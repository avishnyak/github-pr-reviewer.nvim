-- Run with: nvim --headless -u NONE -c 'set rtp+=.' -l tests/orphaned_review.lua
-- A review branch left checked out with no review loaded (e.g. the session file is gone)
local pr_reviewer = require("github-pr-reviewer")
pr_reviewer.setup()
local git = require("github-pr-reviewer.git")
local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")

local function run(args)
  local result = vim.fn.system("git -C " .. vim.fn.shellescape(repo) .. " " .. args)
  assert(vim.v.shell_error == 0, args .. ": " .. result)
  return result
end

run("init -b dev")
run("config user.email reviewer-test@example.com")
run("config user.name ReviewerTest")
vim.fn.writefile({ "original" }, repo .. "/changed.py")
vim.fn.writefile({ "original" }, repo .. "/deleted.py")
run("add .")
run("commit -m initial")

local review_branch = pr_reviewer.config.branch_prefix .. "repconnex-bugfix/GEP-1/fix_to_dev"
run("checkout -b " .. vim.fn.shellescape(review_branch))
vim.fn.writefile({ "review" }, repo .. "/changed.py")
vim.fn.delete(repo .. "/deleted.py")
vim.fn.writefile({ "new" }, repo .. "/added.py")
vim.fn.chdir(repo)
assert(vim.g.pr_review_number == nil)

-- Re-creating the checked-out review branch fails with a pointer to the fix
local created, create_err
git.create_review_branch(review_branch, "dev", function(ok, err) created, create_err = ok, err end)
assert(created == false and create_err:find(":PRReviewCleanup", 1, true), create_err)

-- :PRReview offers to discard the branch (no session to resume), then lists PRs.
-- Cleanup works without saved state and returns to the base from the branch name.
local prompted_choices
vim.ui.select = function(choices, _, on_choice)
  prompted_choices = choices
  on_choice(choices[#choices])
end
local listed = false
require("github-pr-reviewer.github").list_open_prs = function()
  listed = true
  return {}
end
pr_reviewer.review_pr()
assert(#prompted_choices == 1 and prompted_choices[1]:find("^Discard"), vim.inspect(prompted_choices))
assert(vim.wait(5000, function() return listed end), "orphaned cleanup did not continue to the PR list")
assert(run("branch --show-current"):match("^dev"))
assert(run("status --porcelain") == "", "cleanup left the base branch dirty")
assert(run("branch --list " .. vim.fn.shellescape(review_branch)) == "", "review branch was not deleted")
assert(vim.fn.readfile(repo .. "/changed.py")[1] == "original")
assert(vim.fn.filereadable(repo .. "/deleted.py") == 1)
assert(vim.fn.filereadable(repo .. "/added.py") == 0)

print("orphaned review test passed")

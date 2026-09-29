-- Run with: nvim --headless -u NONE -c 'set rtp+=.' -l tests/cleanup_review.lua
local git = require("github-pr-reviewer.git")
local repo = vim.fn.tempname()
local original_cwd = vim.fn.getcwd()
vim.fn.mkdir(repo, "p")

local function run(args)
  local result = vim.fn.system("git -C " .. vim.fn.shellescape(repo) .. " " .. args)
  assert(vim.v.shell_error == 0, args .. ": " .. result)
  return result
end

run("init -b main")
run("config user.email reviewer-test@example.com")
run("config user.name ReviewerTest")
vim.fn.mkdir(repo .. "/src", "p")
vim.fn.writefile({ "original" }, repo .. "/src/deleted.py")
vim.fn.writefile({ "original" }, repo .. "/src/changed.py")
run("add .")
run("commit -m initial")
local merge_base = run("rev-parse HEAD"):gsub("%s+$", "")
vim.fn.writefile({ "base" }, repo .. "/src/base_only.py")
run("add .")
run("commit -m base-update")
run("checkout -b review-test")
vim.fn.writefile({ "edited in review" }, repo .. "/src/base_only.py")
vim.fn.delete(repo .. "/src/deleted.py")
vim.fn.writefile({ "review" }, repo .. "/src/changed.py")
vim.fn.writefile({ "new" }, repo .. "/src/added.py")
vim.fn.chdir(repo)

local files, err = git.get_review_cleanup_files(merge_base)
assert(files and not err)
local paths = {}
for _, file in ipairs(files) do paths[file.path] = file.status end
assert(paths["src/deleted.py"] == "D")
assert(paths["src/changed.py"] == "M")
assert(paths["src/added.py"] == "?")
assert(paths["src/base_only.py"] == "A")
vim.g.pr_review_modified_files = files

local completed, ok, message = false
-- The async line lookup has not completed yet: cleanup must still use the snapshot.
git.cleanup_review("review-test", "main", function(success, failure)
  ok, message, completed = success, failure, true
end)
assert(vim.wait(5000, function() return completed end), "cleanup timed out")
assert(ok, message)
assert(run("branch --show-current"):match("main"))
assert(run("status --porcelain") == "", "cleanup left the target branch dirty")
assert(vim.fn.filereadable(repo .. "/src/deleted.py") == 1)
assert(vim.fn.filereadable(repo .. "/src/added.py") == 0)
assert(vim.fn.readfile(repo .. "/src/base_only.py")[1] == "base")

-- Missing state must not silently check out and carry deletions to main.
run("checkout -b review-again")
vim.fn.delete(repo .. "/src/deleted.py")
vim.g.pr_review_modified_files = nil
local rejected = false
git.cleanup_review("review-again", "main", function(success)
  rejected = not success
end)
assert(rejected and run("branch --show-current"):match("review%-again"))

vim.fn.chdir(original_cwd)
vim.fn.delete(repo, "rf")
print("review cleanup smoke test passed")

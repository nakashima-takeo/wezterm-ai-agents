package.path = package.path .. ";test/?.lua"
local H = require("helper")
local test = H.test

-- 新エージェント追加時の install_plugins.sh case 追記漏れを静的に検知するガード。
-- 旧 test_install_hooks.lua が担っていた「全 id を渡して未知扱いが出ない」検証の置換。
-- 追記漏れは実行時 skip-no-cli (CLI 未インストールと同一出力) に黙って落ちるため、ここで炙る。

-- plugin/service/agents/*.lua の id を集める。
local function agent_ids()
  local ids = {}
  local p = io.popen("ls " .. H.plugin_dir .. "/plugin/service/agents/*.lua 2>/dev/null")
  for line in p:lines() do
    local id = line:match("([^/]+)%.lua$")
    if id then ids[#ids + 1] = id end
  end
  p:close()
  return ids
end

-- install_plugins.sh の明示 case ラベル (claude) / (codex) 等を集める。`*)` フォールバックは除外。
local function case_labels()
  local set = {}
  local content = H.read_file(H.plugin_dir .. "/hooks/install_plugins.sh")
  for label in content:gmatch("\n%s*([%w_]+)%)") do
    set[label] = true
  end
  return set
end

-- CLI を持たない既知の二級市民。自動導入の対象外なので case 不在が正常 (手動導入)。
local ALLOW = { cursor = true }

H.section("install_plugins.sh の case 網羅 (新エージェント追従漏れ検知)")

test("各エージェントは install_plugins.sh の明示 case か許可リストに必ず該当する", function()
  local cases = case_labels()
  local ids = agent_ids()
  H.assert_true(#ids > 0, "service/agents/*.lua が1件も見つからない (テスト前提の破綻)")
  for _, id in ipairs(ids) do
    local covered = cases[id] or ALLOW[id]
    H.assert_true(covered, "agent '" .. id .. "' は install_plugins.sh の case 追記漏れ (skip-no-cli に黙って落ちる)")
  end
end)

H.finish()

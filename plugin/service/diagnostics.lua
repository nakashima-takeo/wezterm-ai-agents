-- ユーザーに知らせるべき失敗を登録・取得・解消する診断通知機構。
-- window を持たない service/state/起動時の経路から report() で登録し、
-- update-status (window あり) 側が take_pending() を toast、active() を右ステータスに出す。
-- log_* はデバッグオーバーレイ止まりでユーザーに届かないため、それを補う統一窓口。

local wezterm = require("wezterm")

local M = {}

local entries = {} -- key -> message (未 resolve のもの)
local order = {} -- 登録順の key 一覧 (表示の安定性のため)
local pending = {} -- 未 toast の key -> true

-- 失敗を登録する。同一 key は上書きで件数は増えない (毎秒の update-status でも溢れない)。
-- デバッグ経路維持のため log_warn も併発する。
function M.report(key, message)
  if not entries[key] then order[#order + 1] = key end
  entries[key] = message
  pending[key] = true
  wezterm.log_warn("[ai-agents] " .. key .. ": " .. message)
end

-- 未 toast の message 群を返し、pending を下ろす (1 回だけ取れる)。
function M.take_pending()
  local out = {}
  for _, key in ipairs(order) do
    if pending[key] then
      out[#out + 1] = entries[key]
      pending[key] = nil
    end
  end
  return out
end

-- 未 resolve の message 一覧 (右ステータス常駐表示用)。
function M.active()
  local out = {}
  for _, key in ipairs(order) do
    if entries[key] then out[#out + 1] = entries[key] end
  end
  return out
end

-- 状況が回復した key を消す (警告を引っ込める)。
function M.resolve(key)
  if not entries[key] then return end
  entries[key] = nil
  pending[key] = nil
  for i, k in ipairs(order) do
    if k == key then
      table.remove(order, i)
      break
    end
  end
end

return M

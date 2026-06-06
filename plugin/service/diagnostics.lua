-- ユーザーに知らせるべき失敗を登録し、window のある場所 (update-status) で
-- 専用タブを生やして表示するための受け渡し。window 非依存の service/state/起動時の
-- 経路から report() で登録できる。log_* はデバッグオーバーレイ止まりでユーザーに届かないため、
-- ユーザー通知は take_pending→タブで行い、log_warn はそれを補うデバッグ用の足跡として残す。

local wezterm = require("wezterm")

local M = {}

local pending = {} -- key -> message (未出力)
local order = {} -- 登録順の key (出力順の安定化)

-- 失敗を登録する。同一 key は上書きで件数を増やさない (毎秒の経路でも溢れない)。
-- log_warn (デバッグ用の足跡) も新規 key のときだけ出し、pending と同様に溢れさせない。
function M.report(key, message)
  local is_new = pending[key] == nil
  if is_new then order[#order + 1] = key end
  pending[key] = message
  if is_new then wezterm.log_warn("[ai-agents] " .. key .. ": " .. message) end
end

-- 未出力の message 群を登録順で返し、pending を空にする (1 回だけ取れる)。
function M.take_pending()
  local out = {}
  for _, key in ipairs(order) do
    if pending[key] ~= nil then out[#out + 1] = pending[key] end
  end
  pending = {}
  order = {}
  return out
end

return M

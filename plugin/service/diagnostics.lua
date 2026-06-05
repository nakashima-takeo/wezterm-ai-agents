-- ユーザーに知らせるべき失敗を登録し、window のある場所 (update-status) で
-- アクティブペインへ端末出力するための受け渡し。window 非依存の service/state/起動時の
-- 経路から report() で登録できる。log_* はデバッグオーバーレイ止まりでユーザーに届かないため、
-- それを補う統一窓口。出力は通常の端末出力なのでユーザーが Ctrl+L 等で消せる。

local wezterm = require("wezterm")

local M = {}

local pending = {} -- key -> message (未出力)
local order = {} -- 登録順の key (出力順の安定化)

-- 失敗を登録する。同一 key は上書きで件数を増やさない (毎秒の経路でも溢れない)。
-- デバッグ経路維持のため log_warn も併発する。
function M.report(key, message)
  if pending[key] == nil then order[#order + 1] = key end
  pending[key] = message
  wezterm.log_warn("[ai-agents] " .. key .. ": " .. message)
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

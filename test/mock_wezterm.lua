-- Minimal `wezterm` global mock for offline unit tests.
-- Captures registered events and config mutations so tests can inspect.

local M = {}

M.home_dir = os.getenv("HOME") or "/tmp"
M.target_triple = "aarch64-apple-darwin"

-- ===== event registry =====
M._events = {}
function M.on(event, callback)
  M._events[event] = M._events[event] or {}
  table.insert(M._events[event], callback)
end

-- ===== text helpers =====
function M.format(parts)
  local out = {}
  for _, p in ipairs(parts or {}) do
    if type(p) == "table" and p.Text then
      table.insert(out, p.Text)
    elseif type(p) == "string" then
      table.insert(out, p)
    end
  end
  return table.concat(out)
end

function M.truncate_right(s, n) return (s or ""):sub(1, n) end
function M.truncate_left(s, n) return (s or ""):sub(-n) end

function M.log_info(...) print("[wezterm.log_info]", ...) end
function M.log_error(...)
  local args = { ... }
  io.stderr:write("[wezterm.log_error] " .. table.concat(args, " ") .. "\n")
end

-- ===== child process =====
function M.run_child_process(_args) return false, "", "(mock)" end
function M.background_child_process(_args) end

-- ===== JSON (cjson if available, else pure-Lua fallback) =====
local ok_cjson, cjson = pcall(require, "cjson")
if ok_cjson then
  M.json_parse = function(s) return cjson.decode(s) end
  M.json_encode = function(t) return cjson.encode(t) end
else
  local function encode_str(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
  end
  local encode_val
  local function is_array(t)
    local n = 0
    for _ in pairs(t) do
      n = n + 1
      if t[n] == nil then return false end
    end
    return true
  end
  encode_val = function(v)
    if v == nil then return "null" end
    local tp = type(v)
    if tp == "boolean" then
      return tostring(v)
    elseif tp == "number" then
      if v ~= v then return "null" end
      if v == math.huge or v == -math.huge then return "null" end
      return string.format("%.14g", v)
    elseif tp == "string" then
      return encode_str(v)
    elseif tp == "table" then
      if is_array(v) then
        local a = {}
        for _, item in ipairs(v) do
          a[#a + 1] = encode_val(item)
        end
        return "[" .. table.concat(a, ",") .. "]"
      else
        local a = {}
        for k, val in pairs(v) do
          a[#a + 1] = encode_str(tostring(k)) .. ":" .. encode_val(val)
        end
        return "{" .. table.concat(a, ",") .. "}"
      end
    end
    return "null"
  end

  local decode_val
  local function skip_ws(s, p) return s:match("^%s*()", p) end
  local function decode_str(s, p)
    if s:byte(p) ~= 34 then return nil, p end
    local i, parts = p + 1, {}
    while i <= #s do
      local c = s:byte(i)
      if c == 34 then return table.concat(parts), i + 1 end
      if c == 92 then
        i = i + 1
        local e = s:sub(i, i)
        if e == "n" then
          parts[#parts + 1] = "\n"
        elseif e == "r" then
          parts[#parts + 1] = "\r"
        elseif e == "t" then
          parts[#parts + 1] = "\t"
        else
          parts[#parts + 1] = e
        end
      else
        parts[#parts + 1] = string.char(c)
      end
      i = i + 1
    end
    return nil, p
  end
  decode_val = function(s, p)
    p = skip_ws(s, p)
    local c = s:byte(p)
    if c == 34 then
      return decode_str(s, p)
    elseif c == 123 then
      p = skip_ws(s, p + 1)
      local obj = {}
      if s:byte(p) == 125 then return obj, p + 1 end
      while true do
        local k
        k, p = decode_str(s, p)
        p = skip_ws(s, p)
        p = p + 1
        p = skip_ws(s, p)
        local v
        v, p = decode_val(s, p)
        obj[k] = v
        p = skip_ws(s, p)
        if s:byte(p) == 125 then return obj, p + 1 end
        p = skip_ws(s, p + 1)
      end
    elseif c == 91 then
      p = skip_ws(s, p + 1)
      local arr = {}
      if s:byte(p) == 93 then return arr, p + 1 end
      while true do
        local v
        v, p = decode_val(s, p)
        arr[#arr + 1] = v
        p = skip_ws(s, p)
        if s:byte(p) == 93 then return arr, p + 1 end
        p = skip_ws(s, p + 1)
      end
    elseif s:sub(p, p + 3) == "true" then
      return true, p + 4
    elseif s:sub(p, p + 4) == "false" then
      return false, p + 5
    elseif s:sub(p, p + 3) == "null" then
      return nil, p + 4
    else
      local ns = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", p)
      if ns then return tonumber(ns), p + #ns end
      return nil, p
    end
  end

  M.json_parse = function(s)
    local v = decode_val(s, 1)
    return v
  end
  M.json_encode = encode_val
end

-- ===== time =====
M.time = { call_after = function(_s, _fn) end }

-- ===== action / action_callback =====
M.action = setmetatable({}, {
  __index = function(_, k)
    return function(arg) return { __action = k, arg = arg } end
  end,
})
function M.action_callback(fn) return { __callback = fn } end

-- ===== misc =====
M.nerdfonts = setmetatable({}, { __index = function() return "?" end })
function M.default_hyperlink_rules() return {} end

-- ===== mux =====
M.mux = {
  all_windows = function() return {} end,
  get_pane = function(_id) return nil end,
  spawn_window = function(_opts) return nil, nil, nil end,
}

-- ===== plugin loader =====
M.plugin = {
  list = function() return {} end,
  require = function(_url) return nil end,
}

-- ===== config builder =====
function M.config_builder()
  return setmetatable({}, { __index = function() return nil end })
end

return M

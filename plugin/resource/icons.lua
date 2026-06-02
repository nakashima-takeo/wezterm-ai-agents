local unicode = {
  working = "●",
  waiting = "◎",
  done = "✔",
  idle = "○",
  unknown = "◌",
  error = "✘",
  pin = "📌",
  folder = "📁",
}

local nerd = {
  working = "\xEF\x83\xA7",
  waiting = "\xEF\x81\x99",
  done = "\xF3\xB0\x82\x9A",
  idle = "\xF3\xB0\x92\xB2",
  unknown = "\xF3\xB0\x8A\xA0",
  error = "\xF3\xB0\x9C\x9A",
  pin = "\xF3\xB0\x9B\x83",
  folder = "\xF3\xB0\x89\x8B",
}

return { unicode = unicode, nerd = nerd }

local unicode = {
  working = "●",
  waiting = "◎",
  done = "✔",
  idle = "○",
  unknown = "◌",
}

local nerd = {
  working = "\xEF\x83\xA7",
  waiting = "\xEF\x81\x99",
  done = "\xF3\xB0\x82\x9A",
  idle = "\xF3\xB0\x92\xB2",
  unknown = "\xF3\xB0\x8A\xA0",
}

return { unicode = unicode, nerd = nerd }

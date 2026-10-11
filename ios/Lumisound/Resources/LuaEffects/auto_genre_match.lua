-- Auto Genre Match — reads the actual playing track's genre tag (via the
-- `track` global every effect script now gets — nil if there's no specific
-- track to read, e.g. previewing from the list) and blends toward whichever
-- reference curve fits best, re-blending fresh every time the track
-- changes. Falls back to a neutral blend when there's no track, or no
-- genre tag, to read.

local curves = {
  electronic = { 5.0, 3.5, 0.0, -1.5, -1.0, 0.5, 2.0, 3.5, 4.0, 3.0 },
  rock       = { 4.0, 2.5, -1.0, -2.0, -1.0, 1.0, 2.5, 3.0, 2.0, 1.5 },
  acoustic   = { 1.0, 0.5, 0.0, 0.5, 1.0, 1.0, 0.5, 0.0, 0.5, 1.0 },
  classical  = { 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.0, 0.5, 1.0, 1.5 },
  default_   = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
}

-- Keyword match rather than an exact lookup — real genre tags are messy
-- ("Alternative Rock", "Classic Rock", "EDM/Electronic") far more often
-- than they're one of a short fixed list.
local function curve_for_genre(genre)
  if not genre or genre == "" then return curves.default_ end
  local lower = genre:lower()
  if lower:find("electronic") or lower:find("edm") or lower:find("house") or lower:find("techno") then
    return curves.electronic
  elseif lower:find("rock") or lower:find("metal") or lower:find("punk") then
    return curves.rock
  elseif lower:find("acoustic") or lower:find("folk") or lower:find("singer") then
    return curves.acoustic
  elseif lower:find("classical") or lower:find("orchestra") then
    return curves.classical
  end
  return curves.default_
end

local genre = track and track.genre or nil
local matched = curve_for_genre(genre)

local eq_bands = {}
for i = 1, 10 do
  eq_bands[i] = matched[i]
end

effect = {
  id = "auto_genre_match",
  name = "Auto Genre Match",
  icon = "wand.and.stars",
  eq_bands = eq_bands,
  eq_enabled = true,
  speed = 1.0,
  pitch_semitones = 0.0,
}

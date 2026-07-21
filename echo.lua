-- Echo hotkey recorder for Hammerspoon.
-- Hold the hotkey to record, release to transcribe. Requires `sox`
-- (brew install sox) for the `rec` command-line recorder.
--
-- Installed and kept up to date automatically via Homebrew:
--   brew tap joyinfant99/echo && brew install echo-hotkey
-- See mac/README.md for manual setup instead.

local M = {}

-- Config lives in a separate file (~/.hammerspoon/echo_config.lua, from
-- echo_config.lua.example) on purpose: this file gets replaced on every
-- update, that one never does, so your real apiUrl/apiKey always survive.
M.config = require("echo_config")

--------------------------------------------------------------------------
-- Glass orb HUD: a small round liquid-glass indicator pinned near the
-- bottom of the screen, replacing Hammerspoon's default centered
-- hs.alert popups. Deliberately not a status bar with text — the point is
-- that each state reads from its motion alone: a flowing wave line while
-- recording, a soft breathing glow while transcribing, a quick expanding
-- ping on success. It only widens into a text capsule for the rare
-- error/info case (no speech detected, a request failing) where a message
-- actually needs to be read. Motion inspired loosely by how Siri signals
-- "listening"/"thinking" state through animation alone, but deliberately
-- monochrome glass rather than a colorful blob, so it doesn't read as a
-- Siri knockoff.
--------------------------------------------------------------------------

local ORB_D = 52 -- diameter of the compact circular orb (recording/processing/success)
local WIDE_W = 220 -- width when widened into a capsule to show an error/info message
local BOTTOM_MARGIN = 30 -- lower/closer to the screen edge, out of the way of text boxes
local ORB_RADIUS = ORB_D / 2

-- The canvas window itself has to be bigger than the visible orb so the
-- layered shadow and completion ping have room to bleed outward without
-- being clipped at the canvas edge.
local SHADOW_PAD = 14

local GRANULE_COUNT = 26
local WAVE_AMPLITUDE = 12 -- max vertical deflection of the recording wave, px
local granuleParams = nil -- per-granule fixed size/phase/speed variance, set once in ensurePill

local COLOR_PINK = { r = 0.95, g = 0.35, b = 0.55 }
local COLOR_VIOLET = { r = 0.55, g = 0.35, b = 0.9 }

local pill = nil
local currentWidth = ORB_D
local waveTimer = nil   -- must stay referenced: an unreferenced hs.timer can
local breatheTimer = nil -- get garbage-collected before it fires (confirmed
local pingTimer = nil    -- empirically), silently dropping the callback
local hideTimer = nil
local wavePhase = 0
local breathePhase = 0
local micLevel = 0       -- latest level parsed from sox's meter, 0..1
local micLevelSmoothed = 0

local function pillFrame(width)
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  return {
    x = screen.x + (screen.w - width) / 2 - SHADOW_PAD,
    y = screen.y + screen.h - BOTTOM_MARGIN - ORB_D - SHADOW_PAD,
    w = width + SHADOW_PAD * 2,
    h = ORB_D + SHADOW_PAD * 2,
  }
end

-- Re-lays out the shadow/glass/label elements for the given width (ORB_D
-- for the compact circle states, WIDE_W for the text-capsule states) --
-- height and corner radius never change, only how wide the capsule is.
local function layout(width)
  currentWidth = width
  pill:frame(pillFrame(width))
  pill["shadow3"].frame = { x = SHADOW_PAD - 4, y = SHADOW_PAD + 5, w = width + 8, h = ORB_D }
  pill["shadow2"].frame = { x = SHADOW_PAD - 2, y = SHADOW_PAD + 3, w = width + 4, h = ORB_D }
  pill["shadow1"].frame = { x = SHADOW_PAD, y = SHADOW_PAD + 1.5, w = width, h = ORB_D }
  pill["bg"].frame = { x = SHADOW_PAD, y = SHADOW_PAD, w = width, h = ORB_D }
  pill["label"].frame = {
    x = SHADOW_PAD + ORB_D + 10,
    y = SHADOW_PAD + (ORB_D - 16) / 2,
    w = width - ORB_D - 22,
    h = 16,
  }
end

local function ensurePill()
  if pill then return end

  pill = hs.canvas.new(pillFrame(ORB_D))
  pill:level(hs.canvas.windowLevels.overlay)
  pill:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

  -- A soft, layered shadow instead of hs.canvas's own per-element shadow
  -- property, which renders against the bounding box rather than the
  -- rounded path and spills a rectangular halo past the curved corners on
  -- light backgrounds (confirmed empirically). Three progressively larger,
  -- more transparent, further-offset rounded rects fake a soft drop shadow
  -- that still follows the orb's own curve.
  pill[1] = {
    id = "shadow3",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.05 },
    roundedRectRadii = { xRadius = ORB_RADIUS + 3, yRadius = ORB_RADIUS + 3 },
    frame = { x = SHADOW_PAD - 4, y = SHADOW_PAD + 5, w = ORB_D + 8, h = ORB_D },
  }
  pill[2] = {
    id = "shadow2",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.08 },
    roundedRectRadii = { xRadius = ORB_RADIUS + 1, yRadius = ORB_RADIUS + 1 },
    frame = { x = SHADOW_PAD - 2, y = SHADOW_PAD + 3, w = ORB_D + 4, h = ORB_D },
  }
  pill[3] = {
    id = "shadow1",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.13 },
    roundedRectRadii = { xRadius = ORB_RADIUS, yRadius = ORB_RADIUS },
    frame = { x = SHADOW_PAD, y = SHADOW_PAD + 1.5, w = ORB_D, h = ORB_D },
  }

  -- Liquid-glass body: a radial gradient (rather than flat/linear fill)
  -- with the highlight offset toward the upper-left, like light catching
  -- a glass sphere, plus a cool greyish border for definition. Stays
  -- neutral/monochrome always -- color only ever appears in the thin
  -- wave/ring/ping accents layered on top, never the glass itself, which
  -- is what keeps this from reading as a colorful Siri-style glow.
  pill[4] = {
    id = "bg",
    type = "rectangle",
    action = "strokeAndFill",
    fillGradient = "radial",
    fillGradientColors = {
      { red = 1, green = 1, blue = 1, alpha = 0.8 },
      { red = 0.82, green = 0.83, blue = 0.86, alpha = 0.42 },
    },
    fillGradientCenter = { x = -0.35, y = -0.35 },
    strokeColor = { red = 0.6, green = 0.61, blue = 0.64, alpha = 0.5 },
    strokeWidth = 1,
    roundedRectRadii = { xRadius = ORB_RADIUS, yRadius = ORB_RADIUS },
    frame = { x = SHADOW_PAD, y = SHADOW_PAD, w = ORB_D, h = ORB_D },
  }

  -- Extra dimensionality on top of the base glass: a thin, low-alpha inner
  -- shadow ring just inside the edge (depth) and a small bright specular
  -- highlight patch near the upper-left (a glossy catch-light, like light
  -- reflecting off a glass sphere) -- both static, always visible, no
  -- animation needed for these two.
  pill[5] = {
    id = "rimShadow",
    type = "circle",
    action = "stroke",
    strokeColor = { white = 0, alpha = 0.1 },
    strokeWidth = 1.5,
    center = { x = SHADOW_PAD + ORB_RADIUS, y = SHADOW_PAD + ORB_RADIUS },
    radius = ORB_RADIUS - 2,
  }
  pill[6] = {
    id = "highlight",
    type = "circle",
    action = "fill",
    fillColor = { red = 1, green = 1, blue = 1, alpha = 0.5 },
    center = { x = SHADOW_PAD + ORB_D * 0.32, y = SHADOW_PAD + ORB_D * 0.28 },
    radius = ORB_D * 0.16,
  }

  -- Recording: a field of small granules (not a clean line) bobbing along
  -- a wave shape, amplitude driven by real mic level -- reads as a denser,
  -- more organic "liquid" motion than a smooth ribbon. Each granule has
  -- its own fixed size/phase/speed variance (picked once, below) so they
  -- move independently rather than in lockstep. No label needed -- the
  -- motion alone reads as "listening".
  granuleParams = {}
  for i = 1, GRANULE_COUNT do
    granuleParams[i] = {
      jitter = math.random() * 6.2832,
      radius = 1.1 + math.random() * 1.3,
      alphaBase = 0.45 + math.random() * 0.5,
      freqMul = 0.85 + math.random() * 0.3,
    }
    pill[6 + i] = {
      id = "granule" .. i,
      type = "circle",
      action = "fill",
      fillColor = { red = 0.85, green = 0.25, blue = 0.25, alpha = 0 }, -- hidden by default
      center = { x = SHADOW_PAD + ORB_RADIUS, y = SHADOW_PAD + ORB_RADIUS },
      radius = granuleParams[i].radius,
    }
  end

  -- Transcribing: a soft glow ring that breathes between two colors (pink
  -- and violet) rather than one flat pulse, distinct motion from the
  -- recording granules so the two states are never confusable at a
  -- glance. A fixed two-tone breathing ring, not a hue-cycling blob --
  -- colorful and distinctive without recreating Siri's animated blob look.
  pill[6 + GRANULE_COUNT + 1] = {
    id = "glowRing",
    type = "circle",
    action = "stroke",
    strokeColor = { red = 0.85, green = 0.6, blue = 0.15, alpha = 0 }, -- hidden by default
    strokeWidth = 2.5,
    center = { x = SHADOW_PAD + ORB_RADIUS, y = SHADOW_PAD + ORB_RADIUS },
    radius = ORB_RADIUS - 4,
  }

  -- Success: a quick burst of staggered expanding, fading rings -- a
  -- "disperse" instead of ever showing the transcribed text, which would
  -- just duplicate what already landed in the real text field.
  for i = 1, 3 do
    pill[6 + GRANULE_COUNT + 1 + i] = {
      id = "ping" .. i,
      type = "circle",
      action = "stroke",
      strokeColor = { red = 0.2, green = 0.65, blue = 0.35, alpha = 0 }, -- hidden by default
      strokeWidth = 2,
      center = { x = SHADOW_PAD + ORB_RADIUS, y = SHADOW_PAD + ORB_RADIUS },
      radius = ORB_RADIUS,
    }
  end

  pill[6 + GRANULE_COUNT + 5] = {
    id = "label",
    type = "text",
    text = "",
    textColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.9 },
    textSize = 12.5,
    textFont = ".AppleSystemUIFont",
    textAlignment = "left",
    frame = {
      x = SHADOW_PAD + ORB_D + 10,
      y = SHADOW_PAD + (ORB_D - 16) / 2,
      w = WIDE_W - ORB_D - 22,
      h = 16,
    },
  }
end

local function stopWave()
  if waveTimer then
    waveTimer:stop()
    waveTimer = nil
  end
  if pill then
    for i = 1, GRANULE_COUNT do
      pill["granule" .. i].fillColor = { red = 0.85, green = 0.25, blue = 0.25, alpha = 0 }
    end
  end
end

local function stopBreathe()
  if breatheTimer then
    breatheTimer:stop()
    breatheTimer = nil
  end
  if pill then
    pill["glowRing"].strokeColor = { red = 0.85, green = 0.6, blue = 0.15, alpha = 0 }
  end
end

local function stopPing()
  if pingTimer then
    pingTimer:stop()
    pingTimer = nil
  end
  if pill then
    for i = 1, 3 do
      pill["ping" .. i].strokeColor = { red = 0.2, green = 0.65, blue = 0.35, alpha = 0 }
    end
  end
end

-- A field of granules bobbing along a wave shape, amplitude driven by the
-- actual mic level (see parseLevelLine below) -- denser and more organic
-- than a clean line, and each granule's own fixed phase/speed variance
-- (picked once in ensurePill) means they move independently rather than
-- in lockstep, closer to "liquid" than a mechanical equalizer.
local function startWave(color)
  stopWave()
  wavePhase = 0
  micLevel = 0
  micLevelSmoothed = 0
  waveTimer = hs.timer.doEvery(0.03, function()
    wavePhase = wavePhase + 0.35
    -- ease toward the latest parsed level so sox's ~8-10Hz updates don't
    -- look like discrete jumps at our ~33Hz render rate
    micLevelSmoothed = micLevelSmoothed + (micLevel - micLevelSmoothed) * 0.55
    if not pill then return end

    for i = 1, GRANULE_COUNT do
      local p = granuleParams[i]
      local t = (i - 1) / (GRANULE_COUNT - 1)
      local x = SHADOW_PAD + 8 + t * (ORB_D - 16)
      -- blend of a fast and a slow component per granule, phase-offset by
      -- its own jitter, so the field ripples rather than moving as one
      local wave = 0.7 * math.sin(wavePhase * p.freqMul + t * 7.5 + p.jitter)
        + 0.3 * math.sin(wavePhase * 0.55 * p.freqMul + t * 4.5 + p.jitter * 1.3)
      local y = SHADOW_PAD + ORB_RADIUS + wave * WAVE_AMPLITUDE * micLevelSmoothed
      pill["granule" .. i].center = { x = x, y = y }
      pill["granule" .. i].fillColor = {
        red = color.r, green = color.g, blue = color.b,
        alpha = p.alphaBase * (0.35 + 0.65 * micLevelSmoothed),
      }
    end
  end)
end

-- Soft breathing glow ring, shifting between two fixed colors (rather
-- than one flat pulse) -- deliberately slower and calmer than the
-- recording granules, so "processing" never looks like "still listening",
-- and colorful/distinctive without cycling through hues like a
-- Siri-style blob (this is a fixed pink<->violet pair, geometric ring).
local function startBreathe(fromColor, toColor)
  stopBreathe()
  breathePhase = 0
  breatheTimer = hs.timer.doEvery(0.04, function()
    breathePhase = breathePhase + 0.05
    local mix = 0.5 + 0.5 * math.sin(breathePhase)
    local alpha = 0.5 + 0.35 * (0.5 + 0.5 * math.sin(breathePhase * 1.7))
    if pill then
      pill["glowRing"].strokeColor = {
        red = fromColor.r + (toColor.r - fromColor.r) * mix,
        green = fromColor.g + (toColor.g - fromColor.g) * mix,
        blue = fromColor.b + (toColor.b - fromColor.b) * mix,
        alpha = alpha,
      }
    end
  end)
end

local COLOR_RED = { r = 0.9, g = 0.25, b = 0.25 }
local COLOR_AMBER = { r = 0.85, g = 0.6, b = 0.15 }
local COLOR_GREEN = { r = 0.2, g = 0.65, b = 0.35 }

local function showWaveform()
  ensurePill()
  layout(ORB_D)
  stopBreathe()
  stopPing()
  pill["label"].text = ""
  pill:show(0.18) -- fluid fade-in rather than an instant pop
  startWave(COLOR_RED)
end

local function showProcessing()
  ensurePill()
  layout(ORB_D)
  stopWave()
  stopPing()
  pill["label"].text = ""
  pill:show(0.18)
  startBreathe(COLOR_PINK, COLOR_VIOLET)
end

-- A quick burst of staggered expanding, fading rings instead of ever
-- showing the transcribed text -- it already landed in the real text
-- field, so showing it again here would just be noise. Three rings, each
-- starting a beat after the last, read as a single "disperse" moment
-- rather than one mechanical pulse.
local PING_STAGGER = 0.12  -- seconds between each ring's start
local PING_DURATION = 0.5  -- how long each individual ring takes to fade out

local function showSuccessPing(color)
  ensurePill()
  layout(ORB_D)
  stopWave()
  stopBreathe()
  stopPing()
  pill["label"].text = ""
  pill:show(0.15)

  local elapsed = 0
  local totalDuration = PING_DURATION + PING_STAGGER * 2
  pingTimer = hs.timer.doEvery(0.02, function()
    elapsed = elapsed + 0.02
    if not pill then return end
    for i = 1, 3 do
      local localElapsed = elapsed - (i - 1) * PING_STAGGER
      local progress = math.max(0, math.min(1, localElapsed / PING_DURATION))
      local alpha = localElapsed <= 0 and 0 or (0.75 * (1 - progress))
      pill["ping" .. i].radius = ORB_RADIUS + progress * (14 + (i - 1) * 4)
      pill["ping" .. i].strokeColor = { red = color.r, green = color.g, blue = color.b, alpha = alpha }
    end
    if elapsed >= totalDuration and pingTimer then
      pingTimer:stop()
      pingTimer = nil
    end
  end)
end

-- Only used for the rare error/info message that actually needs to be
-- read (no speech detected, a request failing) -- widens into a capsule
-- with the glass orb on the left and text on the right.
local function showSteady(text, color)
  ensurePill()
  layout(WIDE_W)
  stopWave()
  stopBreathe()
  stopPing()
  pill["glowRing"].strokeColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.8 }
  pill["label"].text = text
  pill:show(0.18)
end

local function hidePillAfter(delay)
  hideTimer = hs.timer.doAfter(delay, function()
    stopWave()
    stopBreathe()
    stopPing()
    if pill then pill:hide(0.3) end -- fluid fade-out
  end)
end

--------------------------------------------------------------------------
-- Learn-from-correction popup: after Echo types text into whatever app is
-- focused, watch your literal keystrokes for a short window afterward. If
-- you manually retype a single word (e.g. fixing a misheard name), a small
-- popup asks whether to remember that correction for future transcripts.
--
-- This used to work by reading the focused field back via the Accessibility
-- API, but real testing (TextEdit/Notes/Mail work, Claude desktop/Chrome/
-- Slack all do not) showed that rich-text composers in Chromium/Electron
-- apps don't reliably expose their content that way, no matter how the API
-- is queried (confirmed even with the AXManualAccessibility force-on trick).
-- Watching keystrokes instead works identically in every app, since it
-- never depends on what the destination app chooses to expose.
--------------------------------------------------------------------------

local learnPopupTimer = nil     -- must stay referenced, same GC gotcha as hideTimer/sendTimer
local learnPopup = nil
local learnPopupPending = nil

local function tokenize(text)
  local tokens = {}
  for w in text:gmatch("%S+") do
    table.insert(tokens, w)
  end
  return tokens
end

-- Only handles the clean case: same word count, exactly one differing
-- position. Anything messier (multi-word edits, reflowed sentences) is
-- ambiguous enough that we'd rather say nothing than guess wrong.
local function singleWordSubstitution(oldText, newText)
  if oldText == newText then return nil end
  local oldTokens = tokenize(oldText)
  local newTokens = tokenize(newText)
  if #oldTokens == 0 or #oldTokens ~= #newTokens then return nil end

  local diffIndex = nil
  for i = 1, #oldTokens do
    if oldTokens[i] ~= newTokens[i] then
      if diffIndex then return nil end
      diffIndex = i
    end
  end
  if not diffIndex then return nil end

  local alias = oldTokens[diffIndex]:gsub("^%p+", ""):gsub("%p+$", "")
  local term = newTokens[diffIndex]:gsub("^%p+", ""):gsub("%p+$", "")
  if alias == "" or term == "" or alias:lower() == term:lower() then return nil end
  return alias, term
end

local LEARN_W, LEARN_H = 320, 90

local function learnPopupFrame()
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  return {
    x = screen.x + (screen.w - LEARN_W) / 2,
    y = screen.y + screen.h - PILL_BOTTOM_MARGIN - PILL_H - LEARN_H - 14,
    w = LEARN_W,
    h = LEARN_H,
  }
end

local function hideLearnPopup()
  if learnPopupTimer then
    learnPopupTimer:stop()
    learnPopupTimer = nil
  end
  if learnPopup then
    learnPopup:delete()
    learnPopup = nil
  end
  learnPopupPending = nil
end

local function commitLearn()
  if not learnPopupPending then return end
  local alias, term = learnPopupPending.alias, learnPopupPending.term
  hideLearnPopup()

  hs.task.new(M.config.curlPath, function(exitCode, _stdOut, stdErr)
    if exitCode ~= 0 then
      print(string.format("Echo: vocabulary POST failed exit=%s stderr=%s", tostring(exitCode), stdErr or "(none)"))
    end
  end, {
    "-s", "-S", "-X", "POST",
    M.config.apiUrl .. "/vocabulary",
    "-H", "x-api-key: " .. M.config.apiKey,
    "-H", "Content-Type: application/json",
    "-d", hs.json.encode({ term = term, alias = alias }),
  }):start()
end

local function showLearnPrompt(alias, term)
  hideLearnPopup()
  learnPopupPending = { alias = alias, term = term }

  learnPopup = hs.canvas.new(learnPopupFrame())
  learnPopup:level(hs.canvas.windowLevels.overlay)
  learnPopup:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  learnPopup:clickActivating(false) -- clicking a button shouldn't steal focus from the app you're dictating into

  learnPopup[1] = {
    id = "bg",
    type = "rectangle",
    action = "strokeAndFill",
    fillColor = { red = 0.97, green = 0.97, blue = 0.98, alpha = 0.97 },
    strokeColor = { white = 0, alpha = 0.12 },
    strokeWidth = 1,
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
    frame = { x = 0, y = 0, w = LEARN_W, h = LEARN_H },
  }
  learnPopup[2] = {
    id = "text",
    type = "text",
    text = string.format('Use "%s" instead of "%s" from now on?', term, alias),
    textColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.95 },
    textSize = 13,
    textFont = ".AppleSystemUIFont",
    textAlignment = "center",
    frame = { x = 12, y = 12, w = LEARN_W - 24, h = 36 },
  }
  learnPopup[3] = {
    id = "yesBg",
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.2, green = 0.45, blue = 0.9, alpha = 1 },
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
    frame = { x = LEARN_W - 132, y = LEARN_H - 40, w = 120, h = 28 },
    trackMouseUp = true,
  }
  learnPopup[4] = {
    id = "yesText",
    type = "text",
    text = "Yes, learn it",
    textColor = { white = 1, alpha = 1 },
    textSize = 12,
    textFont = ".AppleSystemUIFont",
    textAlignment = "center",
    frame = { x = LEARN_W - 132, y = LEARN_H - 40 + 6, w = 120, h = 18 },
  }
  learnPopup[5] = {
    id = "noBg",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.06 },
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
    frame = { x = 12, y = LEARN_H - 40, w = 100, h = 28 },
    trackMouseUp = true,
  }
  learnPopup[6] = {
    id = "noText",
    type = "text",
    text = "No",
    textColor = { red = 0.2, green = 0.2, blue = 0.22, alpha = 0.85 },
    textSize = 12,
    textFont = ".AppleSystemUIFont",
    textAlignment = "center",
    frame = { x = 12, y = LEARN_H - 40 + 6, w = 100, h = 18 },
  }

  learnPopup:mouseCallback(function(_canvas, event, elementId)
    if event ~= "mouseUp" then return end
    if elementId == "yesBg" then
      commitLearn()
    elseif elementId == "noBg" then
      hideLearnPopup()
    end
  end)

  learnPopup:show(0.15)
  learnPopupTimer = hs.timer.doAfter(9, hideLearnPopup)
end

-- Keystroke-based watch: reconstructs edits locally from Backspace/typing
-- events instead of reading any app's state. Only the clean case is
-- tracked (plain Backspace + plain character keys); anything that breaks
-- the "cursor stayed right after what we typed" assumption (arrows, Cmd
-- shortcuts, switching apps) ends the watch rather than risk a wrong diff.
local KEYSTROKE_WATCH_MAX_SECONDS = 25

local keystrokeWatchTap = nil     -- must stay referenced, same GC gotcha as hideTimer/sendTimer
local keystrokeWatchTimeout = nil -- ditto
local keystrokeOriginalText = nil
local keystrokeShadowText = nil
local keystrokeShadowPos = nil
local keystrokeWatchAppPid = nil

local DELETE_KEYCODE = hs.keycodes.map["delete"] or 51
local RETURN_KEYCODE = hs.keycodes.map["return"] or 36
local TAB_KEYCODE = hs.keycodes.map["tab"] or 48

-- Keys that invalidate our "cursor is still right where we left it"
-- assumption: arrows, escape, forward-delete, home/end/page up/down.
local ABORT_KEYCODES = {
  [53] = true, [123] = true, [124] = true, [125] = true, [126] = true,
  [115] = true, [119] = true, [116] = true, [121] = true, [117] = true,
}

local function finishKeystrokeWatch(shouldDiff)
  if keystrokeWatchTap then
    keystrokeWatchTap:stop()
    keystrokeWatchTap = nil
  end
  if keystrokeWatchTimeout then
    keystrokeWatchTimeout:stop()
    keystrokeWatchTimeout = nil
  end
  if shouldDiff and keystrokeOriginalText and keystrokeShadowText
     and keystrokeOriginalText ~= keystrokeShadowText then
    local alias, term = singleWordSubstitution(keystrokeOriginalText, keystrokeShadowText)
    if alias and term then
      showLearnPrompt(alias, term)
    end
  end
  keystrokeOriginalText = nil
  keystrokeShadowText = nil
  keystrokeShadowPos = nil
  keystrokeWatchAppPid = nil
end

local function startLearnWatch(typedText)
  finishKeystrokeWatch(false)

  keystrokeOriginalText = typedText
  keystrokeShadowText = typedText
  keystrokeShadowPos = #typedText
  local app = hs.application.frontmostApplication()
  keystrokeWatchAppPid = app and app:pid() or nil

  keystrokeWatchTap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.rightMouseDown,
  }, function(event)
    -- A mouse click almost always means repositioning the cursor (e.g.
    -- double-clicking a word to select and retype it) -- exactly how most
    -- real corrections happen, and something we have no way to track from
    -- key events alone. Safer to go silent than splice a correction into
    -- the wrong place in our local reconstruction.
    if event:getType() ~= hs.eventtap.event.types.keyDown then
      finishKeystrokeWatch(false)
      return false
    end

    local app = hs.application.frontmostApplication()
    if not app or app:pid() ~= keystrokeWatchAppPid then
      finishKeystrokeWatch(true)
      return false
    end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()

    if flags.cmd or flags.ctrl or flags.fn then
      finishKeystrokeWatch(true)
      return false
    end

    if keyCode == RETURN_KEYCODE or keyCode == TAB_KEYCODE then
      finishKeystrokeWatch(true)
      return false
    end

    if ABORT_KEYCODES[keyCode] then
      finishKeystrokeWatch(false)
      return false
    end

    if keyCode == DELETE_KEYCODE then
      if keystrokeShadowPos > 0 then
        keystrokeShadowText = keystrokeShadowText:sub(1, keystrokeShadowPos - 1) ..
                               keystrokeShadowText:sub(keystrokeShadowPos + 1)
        keystrokeShadowPos = keystrokeShadowPos - 1
      end
      return false
    end

    local chars = event:getCharacters()
    if chars and #chars > 0 and chars:match("^[%g%s]+$") then
      keystrokeShadowText = keystrokeShadowText:sub(1, keystrokeShadowPos) .. chars ..
                             keystrokeShadowText:sub(keystrokeShadowPos + 1)
      keystrokeShadowPos = keystrokeShadowPos + #chars
    end

    return false
  end)
  keystrokeWatchTap:start()

  keystrokeWatchTimeout = hs.timer.doAfter(KEYSTROKE_WATCH_MAX_SECONDS, function()
    finishKeystrokeWatch(true)
  end)
end

--------------------------------------------------------------------------
-- Recording flow
--------------------------------------------------------------------------

-- sox's forced progress meter (-S) prints lines like:
--   In:0.00% 00:00:00.34 [00:00:00.00] Out:3.92k [  ====|====  ]  Clip:0
-- separated by \r. The bracketed VU bar fills outward from the center "|"
-- with "=" (and "-" once it saturates) as input volume rises, so counting
-- filled characters on the louder side gives a real, if coarse, level.
local function parseLevelLine(line)
  local bar = line:match("%[([%s%-=]*|[%s%-=]*)%]")
  if not bar then return nil end
  local pipePos = bar:find("|")
  if not pipePos then return nil end
  local left = bar:sub(1, pipePos - 1)
  local right = bar:sub(pipePos + 1)
  local halfWidth = math.max(#left, #right)
  if halfWidth == 0 then return 0 end
  local leftFilled = select(2, left:gsub("[=%-]", ""))
  local rightFilled = select(2, right:gsub("[=%-]", ""))
  return math.min(1, math.max(leftFilled, rightFilled) / halfWidth)
end

local recordTask = nil
local recordPath = nil
local levelStderrBuffer = ""
local recordingPeakLevel = 0
local sendTimer = nil  -- must stay referenced, same reason as hideTimer above

-- Below this, a recording is treated as silence rather than speech. Whisper
-- hallucinates words from its own vocabulary prompt hint when fed silent or
-- near-silent audio (a known failure mode of prompted transcription models),
-- so silent recordings are dropped locally instead of ever reaching the API.
local NO_SPEECH_PEAK_THRESHOLD = 0.12

-- The streaming callback must be wired in through hs.task.new's own
-- streamCallbackFn argument, not task:setStreamingCallback() after the
-- fact — the latter silently never fires (confirmed empirically), the
-- former delivers stdErr chunks live as sox writes its progress meter.
local function levelStreamCallback(_task, _stdOut, stdErr)
  if stdErr and #stdErr > 0 then
    levelStderrBuffer = levelStderrBuffer .. stdErr
    while true do
      local cr = levelStderrBuffer:find("\r")
      if not cr then break end
      local segment = levelStderrBuffer:sub(1, cr - 1)
      levelStderrBuffer = levelStderrBuffer:sub(cr + 1)
      local level = parseLevelLine(segment)
      if level then
        micLevel = level
        if level > recordingPeakLevel then recordingPeakLevel = level end
      end
    end
  end
  return true
end

local function startRecording()
  finishKeystrokeWatch(false)
  hideLearnPopup()
  recordPath = os.tmpname() .. ".wav"
  levelStderrBuffer = ""
  recordingPeakLevel = 0
  recordTask = hs.task.new(M.config.soxPath, nil, levelStreamCallback, { "-S", recordPath, "rate", "16000" })
  recordTask:start()
  showWaveform()
end

local function stopRecordingAndSend()
  if not recordTask then
    return
  end
  recordTask:terminate()
  recordTask = nil

  -- Captured now, not read again later: if Fn gets tapped again before this
  -- request's async callback fires, the shared recordPath/module state will
  -- have moved on to the next recording, and reading it late here would
  -- delete or upload the wrong file.
  local thisRecordPath = recordPath

  if recordingPeakLevel < NO_SPEECH_PEAK_THRESHOLD then
    os.remove(thisRecordPath)
    showSteady("No speech detected", COLOR_AMBER)
    hidePillAfter(1.0)
    return
  end

  showProcessing()

  -- give sox a beat to flush the wav file to disk before we read it
  sendTimer = hs.timer.doAfter(0.3, function()
    local task = hs.task.new(M.config.curlPath, function(exitCode, stdOut, stdErr)
      os.remove(thisRecordPath)

      if exitCode ~= 0 then
        -- Printed to the Hammerspoon Console (menu bar icon -> Console) since
        -- the pill only has room for a short label, not the actual cause.
        print(string.format(
          "Echo: curl exit=%s stderr=%s", tostring(exitCode), stdErr or "(none)"
        ))
        showSteady("Echo: request failed", COLOR_RED)
        hidePillAfter(1.4)
        return
      end

      local ok, decoded = pcall(hs.json.decode, stdOut)
      if not ok or not decoded or not decoded.text then
        print(string.format("Echo: bad response body=%s", stdOut or "(empty)"))
        showSteady("Echo: bad response", COLOR_RED)
        hidePillAfter(1.4)
        return
      end

      hs.pasteboard.setContents(decoded.text) -- backup: still on the clipboard if focus moved
      hs.eventtap.keyStrokes(decoded.text)    -- types it directly into whatever's focused

      -- keyStrokes() is synchronous, so starting the keystroke watch here
      -- (rather than after a delay, like the old AX-based version needed)
      -- can't pick up its own synthetic keys.
      startLearnWatch(decoded.text)

      showSuccessPing(COLOR_GREEN)
      hidePillAfter(0.85)

      hs.task.new(M.config.curlPath, nil, {
        "-s", "-X", "PATCH",
        M.config.apiUrl .. "/transcripts/" .. decoded.id,
        "-H", "x-api-key: " .. M.config.apiKey,
        "-H", "Content-Type: application/json",
        "-d", hs.json.encode({ status = "approved" }),
      }):start()
    end, {
      "-s", "-S", "-X", "POST",
      M.config.apiUrl .. "/transcribe",
      "-H", "x-api-key: " .. M.config.apiKey,
      "-F", "source=mac",
      "-F", "file=@" .. thisRecordPath,
    })
    task:start()
  end)
end

-- The bare Fn key is a modifier flag, not a regular key, so it can't go
-- through hs.hotkey.bind (which needs a real key plus optional modifiers).
-- Instead watch flagsChanged events and react on the fn flag's rising and
-- falling edge — this is the standard way to bind Fn alone in Hammerspoon.
local fnPressed = false
local fnWatcher = nil

-- Reverted: consuming (returning true from) the Fn press/release edges was
-- meant to stop macOS's own Fn behavior from firing alongside ours, but it
-- broke the hotkey outright on every machine, never actually verified with
-- a real key press before shipping. Always return false here and rely
-- solely on System Settings -> Keyboard -> "Press Fn key to" -> Do Nothing
-- to prevent macOS's own Fn behavior instead.
local function handleFlagsChanged(event)
  local isFnDown = event:getFlags().fn or false

  if isFnDown and not fnPressed then
    fnPressed = true
    startRecording()
  elseif not isFnDown and fnPressed then
    fnPressed = false
    stopRecordingAndSend()
  end

  return false
end

function M.start()
  fnWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, handleFlagsChanged)
  fnWatcher:start()
end

return M

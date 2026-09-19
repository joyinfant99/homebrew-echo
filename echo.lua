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
-- Pill HUD with waveform bars: a compact horizontal pill pinned near the
-- bottom of the screen, replacing Hammerspoon's default centered
-- hs.alert popups. Each state reads from its motion alone: 9 vertical
-- bars bouncing with mic level while recording, bars breathing pink↔violet
-- while transcribing, a green flash on success. It only widens into a text
-- capsule for the rare error/info case (no speech detected, a request
-- failing) where a message actually needs to be read.
--------------------------------------------------------------------------

local PILL_W = 120 -- width of the compact pill (recording/processing/success)
local PILL_H = 36 -- height of the pill
local PILL_RADIUS = 18 -- half of height for full pill shape
local WIDE_W = 220 -- width when widened into a capsule to show an error/info message
local PILL_BOTTOM_MARGIN = 30 -- lower/closer to the screen edge, out of the way of text boxes

-- The canvas window itself has to be bigger than the visible pill so the
-- layered shadow has room to bleed outward without being clipped at the
-- canvas edge.
local SHADOW_PAD = 14

local BAR_COUNT = 9
local BAR_WIDTH = 4
local BAR_GAP = 5
local BAR_MIN_H = 4
local BAR_MAX_H = 24

local COLOR_PINK = { r = 0.95, g = 0.35, b = 0.55 }
local COLOR_VIOLET = { r = 0.55, g = 0.35, b = 0.9 }

local pill = nil
local currentWidth = PILL_W
local waveTimer = nil    -- must stay referenced: an unreferenced hs.timer can
local breatheTimer = nil -- get garbage-collected before it fires (confirmed
local flashTimer = nil   -- empirically), silently dropping the callback
local hideTimer = nil
local wavePhase = 0
local breathePhase = 0
local micLevel = 0       -- latest level parsed from sox's meter, 0..1
local micLevelSmoothed = 0
local barParams = nil    -- per-bar phase offset for organic wave effect

local function pillFrame(width)
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  return {
    x = screen.x + (screen.w - width) / 2 - SHADOW_PAD,
    y = screen.y + screen.h - PILL_BOTTOM_MARGIN - PILL_H - SHADOW_PAD,
    w = width + SHADOW_PAD * 2,
    h = PILL_H + SHADOW_PAD * 2,
  }
end

-- Re-lays out the shadow/glass/label elements for the given width (PILL_W
-- for the compact pill states, WIDE_W for the text-capsule states) --
-- height and corner radius never change, only how wide the capsule is.
local function layout(width)
  currentWidth = width
  pill:frame(pillFrame(width))
  pill["shadow3"].frame = { x = SHADOW_PAD - 4, y = SHADOW_PAD + 5, w = width + 8, h = PILL_H }
  pill["shadow2"].frame = { x = SHADOW_PAD - 2, y = SHADOW_PAD + 3, w = width + 4, h = PILL_H }
  pill["shadow1"].frame = { x = SHADOW_PAD, y = SHADOW_PAD + 1.5, w = width, h = PILL_H }
  pill["bg"].frame = { x = SHADOW_PAD, y = SHADOW_PAD, w = width, h = PILL_H }

  -- Position bars centered in the pill (for compact mode)
  local totalBarsWidth = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
  local startX = SHADOW_PAD + (width - totalBarsWidth) / 2
  for i = 1, BAR_COUNT do
    local barX = startX + (i - 1) * (BAR_WIDTH + BAR_GAP)
    pill["bar" .. i].frame = {
      x = barX,
      y = SHADOW_PAD + (PILL_H - BAR_MIN_H) / 2,
      w = BAR_WIDTH,
      h = BAR_MIN_H,
    }
  end

  -- Label positioned after bars (for wide/text mode)
  local labelX = SHADOW_PAD + 8 + totalBarsWidth + 10 -- after bars with padding
  pill["label"].frame = {
    x = labelX,
    y = SHADOW_PAD + (PILL_H - 16) / 2,
    w = width - (labelX - SHADOW_PAD) - 10,
    h = 16,
  }
end

local function ensurePill()
  if pill then return end

  pill = hs.canvas.new(pillFrame(PILL_W))
  pill:level(hs.canvas.windowLevels.overlay)
  pill:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

  -- A soft, layered shadow instead of hs.canvas's own per-element shadow
  -- property, which renders against the bounding box rather than the
  -- rounded path and spills a rectangular halo past the curved corners on
  -- light backgrounds (confirmed empirically). Three progressively larger,
  -- more transparent, further-offset rounded rects fake a soft drop shadow
  -- that still follows the pill's own curve.
  pill[1] = {
    id = "shadow3",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.05 },
    roundedRectRadii = { xRadius = PILL_RADIUS + 3, yRadius = PILL_RADIUS + 3 },
    frame = { x = SHADOW_PAD - 4, y = SHADOW_PAD + 5, w = PILL_W + 8, h = PILL_H },
  }
  pill[2] = {
    id = "shadow2",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.08 },
    roundedRectRadii = { xRadius = PILL_RADIUS + 1, yRadius = PILL_RADIUS + 1 },
    frame = { x = SHADOW_PAD - 2, y = SHADOW_PAD + 3, w = PILL_W + 4, h = PILL_H },
  }
  pill[3] = {
    id = "shadow1",
    type = "rectangle",
    action = "fill",
    fillColor = { white = 0, alpha = 0.13 },
    roundedRectRadii = { xRadius = PILL_RADIUS, yRadius = PILL_RADIUS },
    frame = { x = SHADOW_PAD, y = SHADOW_PAD + 1.5, w = PILL_W, h = PILL_H },
  }

  -- Liquid-glass pill body: a radial gradient (rather than flat/linear fill)
  -- with the highlight offset toward the upper-left, plus a cool greyish
  -- border for definition. Stays neutral/monochrome always -- color only
  -- ever appears in the waveform bars layered on top.
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
    roundedRectRadii = { xRadius = PILL_RADIUS, yRadius = PILL_RADIUS },
    frame = { x = SHADOW_PAD, y = SHADOW_PAD, w = PILL_W, h = PILL_H },
  }

  -- Recording/Transcribing/Success: 9 vertical bars that bounce with mic
  -- level while recording, breathe pink↔violet while transcribing, and
  -- flash green on success. Each bar has unique timing parameters for an
  -- organic, liquid feel — like an audio visualizer, not a mechanical meter.
  barParams = {}
  local totalBarsWidth = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
  local startX = SHADOW_PAD + (PILL_W - totalBarsWidth) / 2
  local centerIndex = math.ceil(BAR_COUNT / 2) -- index 5 for 9 bars
  for i = 1, BAR_COUNT do
    local distFromCenter = math.abs(i - centerIndex)
    -- Each bar has unique randomized parameters for organic movement
    barParams[i] = {
      -- Multiple phase offsets for layered sine waves
      phase1 = distFromCenter * 0.4 + math.random() * 0.5,
      phase2 = math.random() * 6.28,
      phase3 = math.random() * 6.28,
      -- Frequency multipliers for variation
      freq1 = 0.9 + math.random() * 0.2,
      freq2 = 0.4 + math.random() * 0.3,
      freq3 = 1.5 + math.random() * 0.5,
      -- How much each bar responds to mic level (center = strongest)
      sensitivity = 1 - distFromCenter * 0.08,
      -- Base "idle" height variation (larger = more visible idle motion)
      baseHeight = 0.35 + math.random() * 0.2,
      -- Current smoothed height for spring physics
      currentHeight = BAR_MIN_H,
      velocity = 0,
    }
    local barX = startX + (i - 1) * (BAR_WIDTH + BAR_GAP)
    pill[4 + i] = {
      id = "bar" .. i,
      type = "rectangle",
      action = "fill",
      fillColor = { red = 0.9, green = 0.25, blue = 0.25, alpha = 0 }, -- hidden by default
      roundedRectRadii = { xRadius = 2, yRadius = 2 },
      frame = {
        x = barX,
        y = SHADOW_PAD + (PILL_H - BAR_MIN_H) / 2,
        w = BAR_WIDTH,
        h = BAR_MIN_H,
      },
    }
  end

  pill[4 + BAR_COUNT + 1] = {
    id = "label",
    type = "text",
    text = "",
    textColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.9 },
    textSize = 12.5,
    textFont = ".AppleSystemUIFont",
    textAlignment = "left",
    frame = {
      x = SHADOW_PAD + PILL_H + 10,
      y = SHADOW_PAD + (PILL_H - 16) / 2,
      w = WIDE_W - PILL_H - 22,
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
    for i = 1, BAR_COUNT do
      pill["bar" .. i].fillColor = { red = 0.9, green = 0.25, blue = 0.25, alpha = 0 }
    end
  end
end

local function stopBreathe()
  if breatheTimer then
    breatheTimer:stop()
    breatheTimer = nil
  end
  if pill then
    for i = 1, BAR_COUNT do
      pill["bar" .. i].fillColor = { red = 0.9, green = 0.25, blue = 0.25, alpha = 0 }
    end
  end
end

local function stopFlash()
  if flashTimer then
    flashTimer:stop()
    flashTimer = nil
  end
end

-- Flowing wave animation — bars form a sine wave pattern that travels
-- horizontally, with amplitude driven by mic level. Creates a liquid,
-- organic audio visualizer look rather than bars bouncing in unison.
local function startWave(color)
  stopWave()
  wavePhase = 0
  micLevel = 0
  micLevelSmoothed = 0
  local totalBarsWidth = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
  local startX = SHADOW_PAD + (currentWidth - totalBarsWidth) / 2

  waveTimer = hs.timer.doEvery(0.025, function()  -- ~40fps for smooth motion
    wavePhase = wavePhase + 0.18  -- wave speed
    -- Smooth mic level transitions
    micLevelSmoothed = micLevelSmoothed + (micLevel - micLevelSmoothed) * 0.4
    if not pill then return end

    for i = 1, BAR_COUNT do
      local p = barParams[i]

      -- Position along the wave (0 to 1 across all bars)
      local position = (i - 1) / (BAR_COUNT - 1)

      -- Primary traveling wave — flows left to right
      local travelingWave = math.sin(wavePhase + position * math.pi * 2)

      -- Secondary wave at different frequency for organic feel
      local secondaryWave = math.sin(wavePhase * 0.7 + position * math.pi * 3 + p.phase2) * 0.3

      -- Combine waves: primary + secondary + small random variation
      local combinedWave = travelingWave * 0.7 + secondaryWave + math.sin(wavePhase * p.freq3 + p.phase3) * 0.15

      -- Normalize to 0-1 range
      combinedWave = (combinedWave + 1.15) / 2.3

      -- Base amplitude (idle) + mic-driven boost
      local baseAmplitude = 0.25 + 0.15 * math.sin(wavePhase * 0.3 + p.phase1)
      local micBoost = micLevelSmoothed * p.sensitivity * 0.7
      local amplitude = baseAmplitude + micBoost

      -- Final height: wave shape modulated by amplitude
      local targetRatio = amplitude * (0.4 + 0.6 * combinedWave)
      targetRatio = math.max(0.1, math.min(1, targetRatio))
      local targetHeight = BAR_MIN_H + (BAR_MAX_H - BAR_MIN_H) * targetRatio

      -- Smooth spring physics
      local displacement = targetHeight - p.currentHeight
      p.velocity = p.velocity * 0.75 + displacement * 0.2
      p.currentHeight = p.currentHeight + p.velocity

      local height = math.max(BAR_MIN_H, math.min(BAR_MAX_H, p.currentHeight))
      local barX = startX + (i - 1) * (BAR_WIDTH + BAR_GAP)
      local barY = SHADOW_PAD + (PILL_H - height) / 2

      pill["bar" .. i].frame = {
        x = barX,
        y = barY,
        w = BAR_WIDTH,
        h = height,
      }

      local alpha = 0.6 + 0.35 * combinedWave
      pill["bar" .. i].fillColor = {
        red = color.r, green = color.g, blue = color.b,
        alpha = alpha,
      }
    end
  end)
end

-- Calm breathing animation for transcribing state. Bars gently pulse with
-- a flowing wave pattern, shifting between pink and violet. Much slower and
-- more meditative than the recording animation — clearly "thinking", not
-- "listening". Uses the same organic multi-wave approach for consistency.
local function startBreathe(fromColor, toColor)
  stopBreathe()
  breathePhase = 0
  local totalBarsWidth = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
  local startX = SHADOW_PAD + (currentWidth - totalBarsWidth) / 2

  breatheTimer = hs.timer.doEvery(0.03, function()
    breathePhase = breathePhase + 0.04  -- slower than recording
    if not pill then return end

    for i = 1, BAR_COUNT do
      local p = barParams[i]

      -- Layered waves for organic movement (slower frequencies for calm feel)
      local wave1 = math.sin(breathePhase * p.freq1 * 0.6 + p.phase1) * 0.5
      local wave2 = math.sin(breathePhase * p.freq2 * 0.5 + p.phase2) * 0.35
      local wave3 = math.sin(breathePhase * p.freq3 * 0.4 + p.phase3) * 0.15
      local combinedWave = (wave1 + wave2 + wave3) * 0.5 + 0.5

      -- Color mixing based on combined wave
      local mix = combinedWave

      -- Height breathes gently: 40-75% of max, with spring smoothing
      local targetRatio = 0.4 + 0.35 * combinedWave
      local targetHeight = BAR_MIN_H + (BAR_MAX_H - BAR_MIN_H) * targetRatio

      -- Gentle spring physics for smooth transitions
      local displacement = targetHeight - p.currentHeight
      p.velocity = p.velocity * 0.85 + displacement * 0.08
      p.currentHeight = p.currentHeight + p.velocity

      local height = math.max(BAR_MIN_H, math.min(BAR_MAX_H, p.currentHeight))
      local barX = startX + (i - 1) * (BAR_WIDTH + BAR_GAP)
      local barY = SHADOW_PAD + (PILL_H - height) / 2

      pill["bar" .. i].frame = {
        x = barX,
        y = barY,
        w = BAR_WIDTH,
        h = height,
      }
      -- Smooth color transition with gentle alpha pulse
      local alpha = 0.65 + 0.25 * combinedWave
      pill["bar" .. i].fillColor = {
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
  layout(PILL_W)
  stopBreathe()
  stopFlash()
  pill["label"].text = ""
  pill:show(0.18) -- fluid fade-in rather than an instant pop
  startWave(COLOR_RED)
end

local function showProcessing()
  ensurePill()
  layout(PILL_W)
  stopWave()
  stopFlash()
  pill["label"].text = ""
  pill:show(0.18)
  startBreathe(COLOR_PINK, COLOR_VIOLET)
end

-- Flash all bars green briefly, then fade out the pill.
local FLASH_DURATION = 0.3

local function showSuccessFlash(color)
  ensurePill()
  layout(PILL_W)
  stopWave()
  stopBreathe()
  stopFlash()
  pill["label"].text = ""
  pill:show(0.15)

  -- Set all bars to success color at full height
  local totalBarsWidth = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
  local startX = SHADOW_PAD + (PILL_W - totalBarsWidth) / 2
  local height = BAR_MAX_H * 0.7

  for i = 1, BAR_COUNT do
    local barX = startX + (i - 1) * (BAR_WIDTH + BAR_GAP)
    local barY = SHADOW_PAD + (PILL_H - height) / 2
    pill["bar" .. i].frame = {
      x = barX,
      y = barY,
      w = BAR_WIDTH,
      h = height,
    }
    pill["bar" .. i].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.9 }
  end
end

-- Only used for the rare error/info message that actually needs to be
-- read (no speech detected, a request failing) -- widens into a capsule
-- with the bars on the left and text on the right.
local function showSteady(text, color)
  ensurePill()
  layout(WIDE_W)
  stopWave()
  stopBreathe()
  stopFlash()
  -- Show bars at steady height with the status color, positioned on the left
  local totalBarsWidth = BAR_COUNT * BAR_WIDTH + (BAR_COUNT - 1) * BAR_GAP
  local startX = SHADOW_PAD + 8 -- left-aligned with small padding
  local height = BAR_MAX_H * 0.5
  for i = 1, BAR_COUNT do
    local barX = startX + (i - 1) * (BAR_WIDTH + BAR_GAP)
    local barY = SHADOW_PAD + (PILL_H - height) / 2
    pill["bar" .. i].frame = {
      x = barX,
      y = barY,
      w = BAR_WIDTH,
      h = height,
    }
    pill["bar" .. i].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.7 }
  end
  pill["label"].text = text
  pill:show(0.18)
end

local function hidePillAfter(delay)
  hideTimer = hs.timer.doAfter(delay, function()
    stopWave()
    stopBreathe()
    stopFlash()
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
  hs.sound.getByName("Frog"):play()
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

      showSuccessFlash(COLOR_GREEN)
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
  -- Reload Config re-runs this without the process restarting, so stale
  -- watchers and canvases from the previous load must be cleaned up first.
  if fnWatcher then
    fnWatcher:stop()
  end
  -- Delete old pill canvas so ensurePill() creates a fresh one with the
  -- current design (important when the HUD layout changes between versions).
  if pill then
    pill:delete()
    pill = nil
  end
  barParams = nil
  fnWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, handleFlagsChanged)
  fnWatcher:start()
end

return M

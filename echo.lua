-- Echo hotkey recorder for Hammerspoon.
-- Hold the hotkey to record, release to transcribe. Requires `sox`
-- (brew install sox) for the `rec` command-line recorder.

local M = {}

-- Config lives in a separate file (~/.hammerspoon/echo_config.lua, from
-- echo_config.lua.example) on purpose: this file gets replaced on every
-- update, that one never does, so your real apiUrl/apiKey always survive.
M.config = require("echo_config")

--------------------------------------------------------------------------
-- Pill HUD: a frosted-glass status pill pinned to the bottom-center of
-- the screen, replacing Hammerspoon's default centered hs.alert popups.
-- Shows an animated waveform while recording, a pulsing dot while
-- transcribing, and a brief confirmation before fading out.
--------------------------------------------------------------------------

local PILL_W, PILL_H = 220, 44
local PILL_BOTTOM_MARGIN = 80
local PILL_MAX_CHARS = 30

local BAR_COUNT = 5
local BAR_WIDTH = 3
local BAR_GAP = 4
local BAR_MIN_H = 4
local BAR_MAX_H = 20
local BARS_X = 20 -- left inset where the waveform starts

local LABEL_X = BARS_X + (BAR_COUNT * BAR_WIDTH) + ((BAR_COUNT - 1) * BAR_GAP) + 12

local pill = nil
local pulseTimer = nil
local pulsePhase = 0
local barTimer = nil
local barPhase = 0
local micLevel = 0       -- latest level parsed from sox's meter, 0..1
local micLevelSmoothed = 0

local function pillFrame()
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  return {
    x = screen.x + (screen.w - PILL_W) / 2,
    y = screen.y + screen.h - PILL_BOTTOM_MARGIN - PILL_H,
    w = PILL_W,
    h = PILL_H,
  }
end

local function barFrame(i, h)
  return {
    x = BARS_X + (i - 1) * (BAR_WIDTH + BAR_GAP),
    y = (PILL_H - h) / 2,
    w = BAR_WIDTH,
    h = h,
  }
end

local function ensurePill()
  if pill then return end

  pill = hs.canvas.new(pillFrame())
  pill:level(hs.canvas.windowLevels.overlay)
  pill:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

  -- Frosted apple-glass look: translucent light grey fill, a soft white
  -- edge highlight. No drop shadow — hs.canvas renders element shadows
  -- against the bounding box rather than the rounded path, which spills a
  -- faint rectangular halo past the curved corners on light backgrounds.
  pill[1] = {
    id = "bg",
    type = "rectangle",
    action = "strokeAndFill",
    fillColor = { red = 0.93, green = 0.93, blue = 0.95, alpha = 0.55 },
    strokeColor = { white = 1, alpha = 0.55 },
    strokeWidth = 1,
    roundedRectRadii = { xRadius = PILL_H / 2, yRadius = PILL_H / 2 },
    frame = { x = 0, y = 0, w = PILL_W, h = PILL_H },
  }

  for i = 1, BAR_COUNT do
    pill[1 + i] = {
      id = "bar" .. i,
      type = "rectangle",
      action = "fill",
      fillColor = { red = 0.85, green = 0.25, blue = 0.25, alpha = 0 }, -- hidden by default
      roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
      frame = barFrame(i, BAR_MIN_H),
    }
  end

  pill[2 + BAR_COUNT] = {
    id = "dot",
    type = "circle",
    action = "fill",
    fillColor = { red = 0.9, green = 0.25, blue = 0.25, alpha = 0 }, -- hidden by default
    center = { x = BARS_X + 6, y = PILL_H / 2 },
    radius = 6,
  }

  pill[3 + BAR_COUNT] = {
    id = "label",
    type = "text",
    text = "",
    textColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.9 },
    textSize = 14,
    textFont = ".AppleSystemUIFont",
    textAlignment = "left",
    frame = { x = LABEL_X, y = (PILL_H - 18) / 2, w = PILL_W - LABEL_X - 16, h = 20 },
  }
end

local function stopPulse()
  if pulseTimer then
    pulseTimer:stop()
    pulseTimer = nil
  end
end

local function stopBars()
  if barTimer then
    barTimer:stop()
    barTimer = nil
  end
  if pill then
    for i = 1, BAR_COUNT do
      pill["bar" .. i].fillColor = { red = 0.85, green = 0.25, blue = 0.25, alpha = 0 }
    end
  end
end

-- Smooth "breathing" alpha on the status dot via a sine wave, instead of a
-- hard blink, so the pill reads as alive rather than a static toast.
local function startPulse(color)
  stopPulse()
  pulsePhase = 0
  pill["dot"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 1 }
  pulseTimer = hs.timer.doEvery(0.05, function()
    pulsePhase = pulsePhase + 0.18
    local alpha = 0.45 + 0.55 * math.sin(pulsePhase)
    if pill then
      pill["dot"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = alpha }
    end
  end)
end

-- Waveform driven by the actual mic level (see parseLevelLine below), with
-- a small per-bar sine wobble layered on top so it still looks organic
-- rather than every bar snapping to the exact same height.
local function startBars(color)
  stopBars()
  barPhase = 0
  micLevel = 0
  micLevelSmoothed = 0
  for i = 1, BAR_COUNT do
    pill["bar" .. i].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.9 }
  end
  barTimer = hs.timer.doEvery(0.045, function()
    barPhase = barPhase + 0.22
    -- ease toward the latest parsed level so sox's ~8-10Hz updates don't
    -- look like discrete jumps at our ~22Hz render rate
    micLevelSmoothed = micLevelSmoothed + (micLevel - micLevelSmoothed) * 0.35
    if not pill then return end
    for i = 1, BAR_COUNT do
      local freq = 1 + (i * 0.37)
      local wobble = 0.85 + 0.15 * math.sin(barPhase * freq + i * 1.3)
      local h = BAR_MIN_H + (BAR_MAX_H - BAR_MIN_H) * micLevelSmoothed * wobble
      h = math.max(BAR_MIN_H, math.min(BAR_MAX_H, h))
      pill["bar" .. i].frame = barFrame(i, h)
    end
  end)
end

local COLOR_RED = { r = 0.9, g = 0.25, b = 0.25 }
local COLOR_AMBER = { r = 0.85, g = 0.6, b = 0.15 }
local COLOR_GREEN = { r = 0.2, g = 0.65, b = 0.35 }

local function setLabel(text)
  pill["label"].text = text
end

local function showWaveform(text)
  ensurePill()
  pill:frame(pillFrame())
  stopPulse()
  pill["dot"].fillColor = { red = 0, green = 0, blue = 0, alpha = 0 }
  setLabel(text)
  pill:show(0.18) -- fluid fade-in rather than an instant pop
  startBars(COLOR_RED)
end

local function showDot(text, color)
  ensurePill()
  pill:frame(pillFrame())
  stopBars()
  setLabel(text)
  pill:show(0.18)
  startPulse(color)
end

local function showSteady(text, color)
  ensurePill()
  pill:frame(pillFrame())
  stopBars()
  stopPulse()
  pill["dot"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 1 }
  setLabel(text)
  pill:show(0.18)
end

local function hidePillAfter(delay)
  hs.timer.doAfter(delay, function()
    stopPulse()
    stopBars()
    if pill then pill:hide(0.3) end -- fluid fade-out
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
  recordPath = os.tmpname() .. ".wav"
  levelStderrBuffer = ""
  recordingPeakLevel = 0
  recordTask = hs.task.new(M.config.soxPath, nil, levelStreamCallback, { "-S", recordPath, "rate", "16000" })
  recordTask:start()
  showWaveform("Recording")
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

  showDot("Transcribing", COLOR_AMBER)

  -- give sox a beat to flush the wav file to disk before we read it
  hs.timer.doAfter(0.3, function()
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

      local preview = decoded.text
      if #preview > PILL_MAX_CHARS then
        preview = preview:sub(1, PILL_MAX_CHARS) .. "..."
      end
      showSteady(preview, COLOR_GREEN)
      hidePillAfter(1.1)

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

local function handleFlagsChanged(event)
  local isFnDown = event:getFlags().fn or false

  if isFnDown and not fnPressed then
    fnPressed = true
    startRecording()
    -- Swallow this specific edge so macOS's own Fn behavior (input source
    -- switch, Emoji picker, Dictation — whatever "Press Fn key to" is set
    -- to) never fires alongside ours. Every other modifier flagsChanged
    -- event still falls through to the `return false` below untouched.
    return true
  elseif not isFnDown and fnPressed then
    fnPressed = false
    stopRecordingAndSend()
    return true
  end

  return false
end

function M.start()
  fnWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, handleFlagsChanged)
  fnWatcher:start()
end

return M

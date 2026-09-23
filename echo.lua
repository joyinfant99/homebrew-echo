-- Echo hotkey recorder for Hammerspoon (v2026.09.23 — Siri-style orb HUD).
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
-- Siri-like Orb HUD: Simulates Apple's Siri orb using layered rotating
-- gradients. Uses 12 color layers that rotate at different speeds, creating
-- the signature swirling effect. Positioned bottom-center of the screen.
-- Amplitude-reactive during recording, faster rotation during processing
-- ("thinking").
--------------------------------------------------------------------------

-- Orb dimensions and positioning
local ORB_DIAMETER = 52          -- compact orb size
local CANVAS_SIZE = 140          -- canvas size (includes glow room)
local ORB_MARGIN_BOTTOM = 35     -- margin from bottom edge

-- Refined Siri color palette - more stops for smoother gradients
local SIRI_COLORS = {
  { r = 0.05, g = 0.55, b = 1.00 },  -- deep cyan
  { r = 0.20, g = 0.45, b = 1.00 },  -- azure
  { r = 0.45, g = 0.30, b = 1.00 },  -- violet
  { r = 0.65, g = 0.20, b = 0.95 },  -- purple
  { r = 0.85, g = 0.18, b = 0.80 },  -- magenta
  { r = 1.00, g = 0.30, b = 0.55 },  -- pink
  { r = 1.00, g = 0.45, b = 0.35 },  -- coral
  { r = 1.00, g = 0.60, b = 0.20 },  -- orange
  { r = 0.70, g = 0.80, b = 0.25 },  -- lime
  { r = 0.25, g = 0.85, b = 0.55 },  -- teal
  { r = 0.15, g = 0.75, b = 0.80 },  -- turquoise
  { r = 0.10, g = 0.60, b = 0.95 },  -- sky
}

-- More layers for smoother, higher-fidelity swirl
local LAYER_COUNT = 12

-- More wave particles for finer fluid effect
local WAVE_COUNT = 16

local orb = nil
local waveParams = nil  -- per-wave-particle animation parameters
local orbTimer = nil     -- must stay referenced: an unreferenced hs.timer can
local hideTimer = nil    -- get garbage-collected before it fires (confirmed empirically)
local orbAngle = 0       -- main rotation angle
local micLevel = 0       -- latest level parsed from sox's meter, 0..1
local micLevelSmoothed = 0
local orbScale = 1       -- current scale (grows with amplitude)
local orbTargetScale = 1
local layerParams = nil  -- per-layer animation parameters
local orbMode = "idle"   -- "idle", "recording", "processing", "success", "text"
local rotationSpeed = 0.08  -- base rotation speed (radians per frame)

-- Orb frame positioned at bottom-center of screen
local function orbFrame()
  local screen = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  return {
    x = screen.x + (screen.w - CANVAS_SIZE) / 2,  -- horizontally centered
    y = screen.y + screen.h - CANVAS_SIZE - ORB_MARGIN_BOTTOM,
    w = CANVAS_SIZE,
    h = CANVAS_SIZE,
  }
end

-- Create the orb canvas with layered rotating color bands
local function ensureOrb()
  if orb then return end

  orb = hs.canvas.new(orbFrame())
  orb:level(hs.canvas.windowLevels.overlay)
  orb:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

  local center = CANVAS_SIZE / 2
  local radius = ORB_DIAMETER / 2

  -- Initialize layer parameters - finer distribution for smoother swirl
  layerParams = {}
  for i = 1, LAYER_COUNT do
    local golden = (i - 1) * 2.39996323  -- golden angle for natural distribution
    layerParams[i] = {
      angleOffset = golden,
      speedMult = 0.5 + (i * 0.08),  -- gentler speed variation
      direction = (i % 3 == 0) and -1 or 1,  -- less uniform direction changes
      orbitRadius = radius * (0.2 + (i / LAYER_COUNT) * 0.35),  -- tighter orbits
      size = radius * (0.25 + (i / LAYER_COUNT) * 0.2),  -- smaller blobs
    }
  end

  -- More glow layers for smoother falloff (5 layers instead of 3)
  orb[1] = {
    id = "glow5",
    type = "circle",
    action = "fill",
    center = { x = center, y = center },
    radius = radius * 1.9,
    fillColor = { red = 0.25, green = 0.35, blue = 0.85, alpha = 0.03 },
  }
  orb[2] = {
    id = "glow4",
    type = "circle",
    action = "fill",
    center = { x = center, y = center },
    radius = radius * 1.6,
    fillColor = { red = 0.35, green = 0.40, blue = 0.90, alpha = 0.05 },
  }
  orb[3] = {
    id = "glow3",
    type = "circle",
    action = "fill",
    center = { x = center, y = center },
    radius = radius * 1.4,
    fillColor = { red = 0.45, green = 0.35, blue = 0.92, alpha = 0.07 },
  }
  orb[4] = {
    id = "glow2",
    type = "circle",
    action = "fill",
    center = { x = center, y = center },
    radius = radius * 1.2,
    fillColor = { red = 0.55, green = 0.35, blue = 0.95, alpha = 0.10 },
  }
  orb[5] = {
    id = "glow1",
    type = "circle",
    action = "fill",
    center = { x = center, y = center },
    radius = radius * 1.05,
    fillColor = { red = 0.60, green = 0.40, blue = 1.0, alpha = 0.14 },
  }

  -- Elements 6-17: The 12 rotating color layers (finer swirl effect)
  local GLOW_COUNT = 5
  for i = 1, LAYER_COUNT do
    local color = SIRI_COLORS[i]
    orb[GLOW_COUNT + i] = {
      id = "layer" .. i,
      type = "circle",
      action = "fill",
      center = { x = center, y = center },
      radius = layerParams[i].size,
      fillGradient = "radial",
      fillGradientColors = {
        { red = color.r, green = color.g, blue = color.b, alpha = 0.55 },
        { red = color.r, green = color.g, blue = color.b, alpha = 0.0 },
      },
    }
  end

  -- Initialize wave particle parameters - finer, more numerous particles
  waveParams = {}
  for i = 1, WAVE_COUNT do
    local golden = (i - 1) * 2.39996323  -- golden angle
    waveParams[i] = {
      phase = golden,
      baseRadius = radius * (0.04 + math.random() * 0.025),  -- 4-6.5% - much smaller
      orbitRadius = radius * (0.08 + (i % 4) * 0.06),  -- tighter orbits, 4 tiers
      speedMult = 0.6 + math.random() * 0.5,
      direction = (i % 3 == 0) and -1 or 1,
      waveFreq = 2.0 + math.random() * 2.0,  -- faster wave frequency
      colorIndex = ((i - 1) % 12) + 1,  -- cycle through all 12 colors
    }
  end

  -- Elements 18-33: Center wave particles (finer fluid dots)
  for i = 1, WAVE_COUNT do
    local color = SIRI_COLORS[waveParams[i].colorIndex]
    orb[GLOW_COUNT + LAYER_COUNT + i] = {
      id = "wave" .. i,
      type = "circle",
      action = "fill",
      center = { x = center, y = center },
      radius = waveParams[i].baseRadius,
      fillGradient = "radial",
      fillGradientColors = {
        { red = color.r, green = color.g, blue = color.b, alpha = 0.85 },
        { red = color.r, green = color.g, blue = color.b, alpha = 0.25 },
      },
    }
  end

  -- Element 34: Bright center core (smaller, crisper)
  orb[GLOW_COUNT + LAYER_COUNT + WAVE_COUNT + 1] = {
    id = "core",
    type = "circle",
    action = "fill",
    center = { x = center, y = center },
    radius = radius * 0.12,
    fillGradient = "radial",
    fillGradientColors = {
      { white = 1, alpha = 0.98 },
      { white = 1, alpha = 0.2 },
    },
  }

  -- Element 35: Text label (for error/info messages)
  orb[GLOW_COUNT + LAYER_COUNT + WAVE_COUNT + 2] = {
    id = "label",
    type = "text",
    text = "",
    textColor = { white = 1, alpha = 0 },
    textSize = 11,
    textFont = ".AppleSystemUIFont",
    textAlignment = "center",
    frame = { x = 0, y = CANVAS_SIZE - 18, w = CANVAS_SIZE, h = 16 },
  }
end

-- Stop any running animation
local function stopAnimation()
  if orbTimer then
    orbTimer:stop()
    orbTimer = nil
  end
end

-- Recording animation: Siri-style swirling, amplitude-reactive
-- Layers rotate and expand with voice, creating the signature liquid effect
local function startRecordingAnimation()
  stopAnimation()
  orbAngle = 0
  micLevel = 0
  micLevelSmoothed = 0
  orbScale = 1
  orbTargetScale = 1
  orbMode = "recording"
  rotationSpeed = 0.06  -- moderate speed for listening

  local center = CANVAS_SIZE / 2
  local radius = ORB_DIAMETER / 2

  orbTimer = hs.timer.doEvery(0.016, function()  -- ~60fps
    -- Smooth mic level and scale
    micLevelSmoothed = micLevelSmoothed + (micLevel - micLevelSmoothed) * 0.25
    orbTargetScale = 1 + micLevelSmoothed * 0.35  -- grow up to 35% with amplitude
    orbScale = orbScale + (orbTargetScale - orbScale) * 0.15

    -- Rotation speed increases slightly with amplitude
    local dynamicSpeed = rotationSpeed * (1 + micLevelSmoothed * 0.5)
    orbAngle = orbAngle + dynamicSpeed

    if not orb then return end

    local scaledRadius = radius * orbScale

    -- Update glows with scale and subtle color shift
    local glowHue = (orbAngle * 0.25) % (math.pi * 2)
    local gr = 0.35 + 0.15 * math.sin(glowHue)
    local gg = 0.35 + 0.15 * math.sin(glowHue + 2.1)
    local gb = 0.85 + 0.10 * math.sin(glowHue + 4.2)

    orb["glow5"].radius = scaledRadius * 1.9
    orb["glow5"].fillColor = { red = gr * 0.4, green = gg * 0.5, blue = gb, alpha = 0.025 + micLevelSmoothed * 0.02 }

    orb["glow4"].radius = scaledRadius * 1.6
    orb["glow4"].fillColor = { red = gr * 0.5, green = gg * 0.55, blue = gb, alpha = 0.04 + micLevelSmoothed * 0.03 }

    orb["glow3"].radius = scaledRadius * 1.4
    orb["glow3"].fillColor = { red = gr * 0.6, green = gg * 0.5, blue = gb, alpha = 0.055 + micLevelSmoothed * 0.04 }

    orb["glow2"].radius = scaledRadius * 1.2
    orb["glow2"].fillColor = { red = gr * 0.7, green = gg * 0.5, blue = gb, alpha = 0.08 + micLevelSmoothed * 0.05 }

    orb["glow1"].radius = scaledRadius * 1.05
    orb["glow1"].fillColor = { red = gr * 0.8, green = gg * 0.55, blue = gb, alpha = 0.11 + micLevelSmoothed * 0.06 }

    -- Animate each color layer - finer orbits, smoother motion
    for i = 1, LAYER_COUNT do
      local p = layerParams[i]
      local layerAngle = orbAngle * p.speedMult * p.direction + p.angleOffset

      -- Orbit radius expands with amplitude
      local orbitR = p.orbitRadius * (1 + micLevelSmoothed * 0.5)

      -- Position on orbit
      local lx = center + math.cos(layerAngle) * orbitR
      local ly = center + math.sin(layerAngle) * orbitR

      -- Subtle size pulses
      local sizePulse = 1 + 0.1 * math.sin(orbAngle * 2.5 + i * 0.5) + micLevelSmoothed * 0.2
      local layerSize = p.size * sizePulse * orbScale

      -- Smoother color intensity variation
      local color = SIRI_COLORS[i]
      local intensity = 0.7 + 0.2 * math.sin(orbAngle * 1.8 + i * 0.6) + micLevelSmoothed * 0.15

      orb["layer" .. i].center = { x = lx, y = ly }
      orb["layer" .. i].radius = layerSize
      orb["layer" .. i].fillGradientColors = {
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.45 + micLevelSmoothed * 0.2 },
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.0 },
      }
    end

    -- Animate center wave particles - finer fluid scatter/gather
    for i = 1, WAVE_COUNT do
      local w = waveParams[i]
      local waveAngle = orbAngle * w.speedMult * w.direction + w.phase

      -- Scatter outward with amplitude, gather back when quiet
      local scatterAmount = micLevelSmoothed * 0.7
      local gatherPulse = math.sin(orbAngle * w.waveFreq + w.phase) * 0.5 + 0.5
      local dynamicOrbit = w.orbitRadius * (0.25 + gatherPulse * 0.6 + scatterAmount)

      -- Position on wave orbit
      local wx = center + math.cos(waveAngle) * dynamicOrbit * orbScale
      local wy = center + math.sin(waveAngle) * dynamicOrbit * orbScale

      -- Subtle size pulses
      local sizePulse = 1 + 0.2 * math.sin(orbAngle * 3.5 + i * 0.5)
      local gatherSize = 1 + (1 - scatterAmount) * 0.3
      local waveSize = w.baseRadius * sizePulse * gatherSize * orbScale

      -- Smoother color intensity
      local color = SIRI_COLORS[w.colorIndex]
      local intensity = 0.75 + 0.2 * math.sin(orbAngle * 2.2 + i * 0.4)

      orb["wave" .. i].center = { x = wx, y = wy }
      orb["wave" .. i].radius = waveSize
      orb["wave" .. i].fillGradientColors = {
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.8 },
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.2 },
      }
    end

    -- Core brightens with amplitude - smaller, crisper
    local coreSize = scaledRadius * (0.10 + micLevelSmoothed * 0.05)
    orb["core"].center = { x = center, y = center }
    orb["core"].radius = coreSize
    orb["core"].fillGradientColors = {
      { white = 1, alpha = 0.95 + micLevelSmoothed * 0.05 },
      { white = 1, alpha = 0.15 + micLevelSmoothed * 0.15 },
    }
  end)
end

-- Processing animation: Faster rotation (2.2x like Siri's "thinking" state)
-- No size changes, just accelerated swirl
local function startProcessingAnimation()
  stopAnimation()
  orbMode = "processing"
  rotationSpeed = 0.13  -- 2.2x faster rotation for "thinking"
  orbScale = 1
  orbTargetScale = 1

  local center = CANVAS_SIZE / 2
  local radius = ORB_DIAMETER / 2

  orbTimer = hs.timer.doEvery(0.016, function()  -- ~60fps
    orbAngle = orbAngle + rotationSpeed

    if not orb then return end

    -- Gentle breathing without amplitude
    local breathe = 0.5 + 0.5 * math.sin(orbAngle * 0.4)

    -- Update glows with subtle shifting colors
    local glowHue = (orbAngle * 0.4) % (math.pi * 2)
    local gr = 0.35 + 0.2 * math.sin(glowHue)
    local gg = 0.35 + 0.2 * math.sin(glowHue + 2.1)
    local gb = 0.80 + 0.15 * math.sin(glowHue + 4.2)

    orb["glow5"].radius = radius * (1.85 + breathe * 0.05)
    orb["glow5"].fillColor = { red = gr * 0.4, green = gg * 0.5, blue = gb, alpha = 0.03 }

    orb["glow4"].radius = radius * (1.55 + breathe * 0.05)
    orb["glow4"].fillColor = { red = gr * 0.5, green = gg * 0.55, blue = gb, alpha = 0.05 }

    orb["glow3"].radius = radius * (1.35 + breathe * 0.05)
    orb["glow3"].fillColor = { red = gr * 0.6, green = gg * 0.5, blue = gb, alpha = 0.07 }

    orb["glow2"].radius = radius * (1.18 + breathe * 0.05)
    orb["glow2"].fillColor = { red = gr * 0.7, green = gg * 0.5, blue = gb, alpha = 0.10 }

    orb["glow1"].radius = radius * (1.03 + breathe * 0.05)
    orb["glow1"].fillColor = { red = gr * 0.8, green = gg * 0.55, blue = gb, alpha = 0.14 }

    -- Layers rotate faster but maintain size
    for i = 1, LAYER_COUNT do
      local p = layerParams[i]
      local layerAngle = orbAngle * p.speedMult * p.direction + p.angleOffset

      local lx = center + math.cos(layerAngle) * p.orbitRadius
      local ly = center + math.sin(layerAngle) * p.orbitRadius

      local sizePulse = 1 + 0.08 * math.sin(orbAngle * 2.8 + i * 0.4)
      local layerSize = p.size * sizePulse

      local color = SIRI_COLORS[i]
      local intensity = 0.75 + 0.18 * math.sin(orbAngle * 2.2 + i * 0.5)

      orb["layer" .. i].center = { x = lx, y = ly }
      orb["layer" .. i].radius = layerSize
      orb["layer" .. i].fillGradientColors = {
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.5 },
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.0 },
      }
    end

    -- Wave particles swirl faster during processing
    for i = 1, WAVE_COUNT do
      local w = waveParams[i]
      local waveAngle = orbAngle * w.speedMult * 1.4 * w.direction + w.phase

      -- Continuous gather/scatter wave pattern
      local gatherPulse = math.sin(orbAngle * w.waveFreq * 1.2 + w.phase) * 0.5 + 0.5
      local dynamicOrbit = w.orbitRadius * (0.3 + gatherPulse * 0.55)

      local wx = center + math.cos(waveAngle) * dynamicOrbit
      local wy = center + math.sin(waveAngle) * dynamicOrbit

      -- Subtle pulsing size
      local sizePulse = 1 + 0.18 * math.sin(orbAngle * 4 + i * 0.5)
      local waveSize = w.baseRadius * sizePulse * (0.9 + gatherPulse * 0.15)

      local color = SIRI_COLORS[w.colorIndex]
      local intensity = 0.8 + 0.15 * math.sin(orbAngle * 2.8 + i * 0.4)

      orb["wave" .. i].center = { x = wx, y = wy }
      orb["wave" .. i].radius = waveSize
      orb["wave" .. i].fillGradientColors = {
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.75 },
        { red = color.r * intensity, green = color.g * intensity, blue = color.b * intensity, alpha = 0.18 },
      }
    end

    -- Core with gentle pulse - smaller, crisper
    orb["core"].center = { x = center, y = center }
    orb["core"].radius = radius * (0.10 + breathe * 0.025)
    orb["core"].fillGradientColors = {
      { white = 1, alpha = 0.95 },
      { white = 1, alpha = 0.18 },
    }
  end)
end

-- Status colors (kept for text messages)
local COLOR_RED = { r = 0.9, g = 0.25, b = 0.25 }
local COLOR_AMBER = { r = 0.85, g = 0.6, b = 0.15 }
local COLOR_GREEN = { r = 0.2, g = 0.75, b = 0.45 }
local COLOR_BLUE = { r = 0.3, g = 0.5, b = 1.0 }

-- Show recording state with animated orb
local function showWaveform()
  ensureOrb()
  orb:frame(orbFrame())
  orb["label"].text = ""
  orb["label"].textColor = { white = 1, alpha = 0 }
  orb:show(0.2)
  startRecordingAnimation()
end

-- Show processing state with calm breathing orb
local function showProcessing()
  ensureOrb()
  orb:frame(orbFrame())
  orb["label"].text = ""
  orb["label"].textColor = { white = 1, alpha = 0 }
  orb:show(0.2)
  startProcessingAnimation()
end

-- Show success with a bright flash effect
local function showSuccessFlash(color)
  ensureOrb()
  stopAnimation()
  orbMode = "success"
  orb:frame(orbFrame())
  orb["label"].text = ""

  local center = CANVAS_SIZE / 2
  local radius = ORB_DIAMETER / 2

  -- Bright success state - all elements glow in success color
  orb["glow5"].radius = radius * 1.8
  orb["glow5"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.12 }
  orb["glow4"].radius = radius * 1.55
  orb["glow4"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.18 }
  orb["glow3"].radius = radius * 1.35
  orb["glow3"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.24 }
  orb["glow2"].radius = radius * 1.18
  orb["glow2"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.32 }
  orb["glow1"].radius = radius * 1.03
  orb["glow1"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.40 }

  for i = 1, LAYER_COUNT do
    orb["layer" .. i].center = { x = center, y = center }
    orb["layer" .. i].radius = radius * 0.7
    orb["layer" .. i].fillGradientColors = {
      { red = color.r, green = color.g, blue = color.b, alpha = 0.4 },
      { red = color.r, green = color.g, blue = color.b, alpha = 0.0 },
    }
  end

  -- Wave particles gather to center on success
  for i = 1, WAVE_COUNT do
    orb["wave" .. i].center = { x = center, y = center }
    orb["wave" .. i].radius = radius * 0.03
    orb["wave" .. i].fillGradientColors = {
      { red = color.r, green = color.g, blue = color.b, alpha = 0.85 },
      { red = color.r, green = color.g, blue = color.b, alpha = 0.35 },
    }
  end

  orb["core"].center = { x = center, y = center }
  orb["core"].radius = radius * 0.14
  orb["core"].fillGradientColors = {
    { white = 1, alpha = 0.98 },
    { red = color.r, green = color.g, blue = color.b, alpha = 0.5 },
  }

  orb:show(0.15)
end

-- Show text message (for errors/info) with colored orb
local function showSteady(text, color)
  ensureOrb()
  stopAnimation()
  orbMode = "text"
  orb:frame(orbFrame())

  local center = CANVAS_SIZE / 2
  local radius = ORB_DIAMETER / 2

  -- Set orb to a steady glow in the status color
  orb["glow5"].radius = radius * 1.6
  orb["glow5"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.08 }
  orb["glow4"].radius = radius * 1.4
  orb["glow4"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.12 }
  orb["glow3"].radius = radius * 1.25
  orb["glow3"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.18 }
  orb["glow2"].radius = radius * 1.1
  orb["glow2"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.25 }
  orb["glow1"].radius = radius * 0.98
  orb["glow1"].fillColor = { red = color.r, green = color.g, blue = color.b, alpha = 0.35 }

  for i = 1, LAYER_COUNT do
    orb["layer" .. i].center = { x = center, y = center }
    orb["layer" .. i].radius = radius * 0.65
    orb["layer" .. i].fillGradientColors = {
      { red = color.r, green = color.g, blue = color.b, alpha = 0.35 },
      { red = color.r, green = color.g, blue = color.b, alpha = 0.0 },
    }
  end

  -- Wave particles in calm arrangement
  for i = 1, WAVE_COUNT do
    local golden = (i - 1) * 2.39996323
    local wx = center + math.cos(golden) * radius * 0.18
    local wy = center + math.sin(golden) * radius * 0.18
    orb["wave" .. i].center = { x = wx, y = wy }
    orb["wave" .. i].radius = radius * 0.028
    orb["wave" .. i].fillGradientColors = {
      { red = color.r, green = color.g, blue = color.b, alpha = 0.65 },
      { red = color.r, green = color.g, blue = color.b, alpha = 0.2 },
    }
  end

  orb["core"].center = { x = center, y = center }
  orb["core"].radius = radius * 0.10
  orb["core"].fillGradientColors = {
    { white = 1, alpha = 0.85 },
    { red = color.r, green = color.g, blue = color.b, alpha = 0.4 },
  }

  -- Show text below the orb
  orb["label"].text = text
  orb["label"].textColor = { white = 1, alpha = 0.95 }

  orb:show(0.18)
end

-- Hide orb after delay with fade out
local function hidePillAfter(delay)
  hideTimer = hs.timer.doAfter(delay, function()
    stopAnimation()
    if orb then orb:hide(0.35) end
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
    x = screen.x + (screen.w - LEARN_W) / 2,  -- centered above the orb
    y = screen.y + screen.h - CANVAS_SIZE - ORB_MARGIN_BOTTOM - LEARN_H - 10,
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

local COLOR_BLUE = { r = 0.2, g = 0.45, b = 0.9 }

-- Auto-saves a vocabulary correction without requiring user confirmation.
-- Called automatically when a clear single-word substitution is detected.
-- Shows a brief HUD notification so the user knows what was learned.
local function autoLearnCorrection(alias, term)
  print(string.format("Echo: auto-learning '%s' → '%s'", alias, term))

  -- Show what was learned in the HUD
  showSteady(string.format("Learned: %s → %s", alias, term), COLOR_BLUE)
  hidePillAfter(2.0)

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

local function commitLearn()
  if not learnPopupPending then return end
  local alias, term = learnPopupPending.alias, learnPopupPending.term
  hideLearnPopup()
  autoLearnCorrection(alias, term)
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
--
-- When a mouse click is detected (e.g. double-click to select), we switch
-- to "accessibility mode": stop keystroke tracking, wait a few seconds,
-- then try to read the focused element's content via Accessibility API.
-- This works for native apps (Notes, TextEdit, Mail) but not Chromium/Electron.
local KEYSTROKE_WATCH_MAX_SECONDS = 25
local ACCESSIBILITY_CHECK_DELAY = 4  -- seconds after click to check
local CLIPBOARD_POLL_INTERVAL = 0.5  -- seconds between clipboard checks

local keystrokeWatchTap = nil     -- must stay referenced, same GC gotcha as hideTimer/sendTimer
local keystrokeWatchTimeout = nil -- ditto
local accessibilityCheckTimer = nil -- timer for delayed Accessibility API check
local clipboardWatchTimer = nil   -- timer for polling clipboard changes
local clipboardLastChangeCount = nil -- to detect clipboard changes
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

-- Try to read the focused element's text content via Accessibility API.
-- Works for native macOS apps (Notes, TextEdit, Mail, etc.) but returns
-- nil for Chromium/Electron apps where the API doesn't expose content.
local function tryReadFocusedText()
  local app = hs.application.frontmostApplication()
  if not app then return nil end

  local elem = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  if not elem then return nil end

  -- Try AXValue first (standard for text fields)
  local value = elem:attributeValue("AXValue")
  if type(value) == "string" and #value > 0 then
    return value
  end

  -- Some apps use AXSelectedText or the element might be a container
  local selected = elem:attributeValue("AXSelectedText")
  if type(selected) == "string" and #selected > 0 then
    return selected
  end

  return nil
end

-- Check for corrections via Accessibility API after a mouse click.
-- Called after a delay when the user likely finished editing.
local function checkAccessibilityForCorrections()
  if not keystrokeOriginalText then return end

  local currentText = tryReadFocusedText()
  if not currentText then
    -- Accessibility didn't work (Chromium/Electron app), give up silently
    -- Clipboard watch is still running as fallback
    return
  end

  -- Look for the original text within the current content
  -- The user may have typed more after the correction, so we search for
  -- a modified version of our original text
  local original = keystrokeOriginalText

  -- Simple approach: if the current text contains a modified version of
  -- what we typed, try to detect single-word substitutions
  -- This is imperfect but catches common cases like name corrections
  local alias, term = singleWordSubstitution(original, currentText)
  if alias and term then
    keystrokeOriginalText = nil  -- clear to prevent duplicate detection
    autoLearnCorrection(alias, term)
    return
  end

  -- If lengths are similar, the edit might be within the same text region
  -- Try comparing if current text is close in length to original
  if math.abs(#currentText - #original) < #original * 0.5 then
    alias, term = singleWordSubstitution(original, currentText)
    if alias and term then
      keystrokeOriginalText = nil
      autoLearnCorrection(alias, term)
    end
  end
end

-- Check clipboard for corrections. Called periodically after Echo types text.
-- Works in all apps including Chrome — triggered when user copies (Cmd+C).
local function checkClipboardForCorrections()
  if not keystrokeOriginalText then return end

  local currentChangeCount = hs.pasteboard.changeCount()
  if currentChangeCount == clipboardLastChangeCount then
    return  -- clipboard hasn't changed
  end
  clipboardLastChangeCount = currentChangeCount

  local clipboardText = hs.pasteboard.getContents()
  if not clipboardText or #clipboardText == 0 then return end

  -- Skip if clipboard is exactly what we typed (user just copied without editing)
  if clipboardText == keystrokeOriginalText then return end

  -- Skip if clipboard is way longer (user copied a whole document)
  if #clipboardText > #keystrokeOriginalText * 3 then return end

  -- Check for single-word substitution
  local alias, term = singleWordSubstitution(keystrokeOriginalText, clipboardText)
  if alias and term then
    keystrokeOriginalText = nil  -- clear to prevent duplicate detection
    autoLearnCorrection(alias, term)
  end
end

-- Start watching clipboard for corrections (works in Chrome and all apps)
local function startClipboardWatch()
  if clipboardWatchTimer then
    clipboardWatchTimer:stop()
  end
  clipboardLastChangeCount = hs.pasteboard.changeCount()
  clipboardWatchTimer = hs.timer.doEvery(CLIPBOARD_POLL_INTERVAL, checkClipboardForCorrections)
end

-- Stop watching clipboard
local function stopClipboardWatch()
  if clipboardWatchTimer then
    clipboardWatchTimer:stop()
    clipboardWatchTimer = nil
  end
  clipboardLastChangeCount = nil
end

local function finishKeystrokeWatch(shouldDiff, switchToAccessibility)
  if keystrokeWatchTap then
    keystrokeWatchTap:stop()
    keystrokeWatchTap = nil
  end
  if keystrokeWatchTimeout then
    keystrokeWatchTimeout:stop()
    keystrokeWatchTimeout = nil
  end
  if accessibilityCheckTimer then
    accessibilityCheckTimer:stop()
    accessibilityCheckTimer = nil
  end

  if switchToAccessibility and keystrokeOriginalText then
    -- Mouse click detected: switch to accessibility mode
    -- Keep keystrokeOriginalText for the delayed check (and clipboard watch continues)
    accessibilityCheckTimer = hs.timer.doAfter(ACCESSIBILITY_CHECK_DELAY, checkAccessibilityForCorrections)
    keystrokeShadowText = nil
    keystrokeShadowPos = nil
    keystrokeWatchAppPid = nil
    return  -- clipboard watch keeps running
  end

  if shouldDiff and keystrokeOriginalText and keystrokeShadowText
     and keystrokeOriginalText ~= keystrokeShadowText then
    local alias, term = singleWordSubstitution(keystrokeOriginalText, keystrokeShadowText)
    if alias and term then
      -- Auto-learn corrections without requiring confirmation popup
      autoLearnCorrection(alias, term)
    end
  end

  -- Full cleanup - stop clipboard watch too
  stopClipboardWatch()
  keystrokeOriginalText = nil
  keystrokeShadowText = nil
  keystrokeShadowPos = nil
  keystrokeWatchAppPid = nil
end

local function startLearnWatch(typedText)
  finishKeystrokeWatch(false, false)

  keystrokeOriginalText = typedText
  keystrokeShadowText = typedText
  keystrokeShadowPos = #typedText
  local app = hs.application.frontmostApplication()
  keystrokeWatchAppPid = app and app:pid() or nil

  -- Start clipboard watch (works in Chrome and all apps)
  startClipboardWatch()

  keystrokeWatchTap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.rightMouseDown,
  }, function(event)
    -- A mouse click (e.g. double-clicking a word to select and retype it)
    -- breaks our keystroke-based tracking. Instead of giving up, switch to
    -- accessibility mode: wait a few seconds then try to read the text via
    -- Accessibility API to detect corrections. Works for native apps only.
    if event:getType() ~= hs.eventtap.event.types.keyDown then
      finishKeystrokeWatch(false, true)  -- true = switch to accessibility mode
      return false
    end

    local app = hs.application.frontmostApplication()
    if not app or app:pid() ~= keystrokeWatchAppPid then
      finishKeystrokeWatch(true, false)
      return false
    end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()

    if flags.cmd or flags.ctrl or flags.fn then
      finishKeystrokeWatch(true, false)
      return false
    end

    if keyCode == RETURN_KEYCODE or keyCode == TAB_KEYCODE then
      finishKeystrokeWatch(true, false)
      return false
    end

    if ABORT_KEYCODES[keyCode] then
      finishKeystrokeWatch(false, false)
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
    finishKeystrokeWatch(true, false)  -- try diff, don't switch to accessibility
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
  finishKeystrokeWatch(false, false)
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

--------------------------------------------------------------------------
-- Rewrite selected text: double-tap Control to rewrite whatever's selected
-- using the same "Joy's voice" rewrite as voice transcripts. Copies the
-- selection, calls /chat/message, pastes the result back.
--------------------------------------------------------------------------

local rewriteTimer = nil  -- must stay referenced (GC gotcha)
local rewriteHotkey = nil

local function rewriteSelectedText()
  hs.sound.getByName("Pop"):play()

  local oldClipboard = hs.pasteboard.getContents()

  -- Copy selection
  hs.eventtap.keyStroke({"cmd"}, "c", 0)

  rewriteTimer = hs.timer.doAfter(0.1, function()
    local selectedText = hs.pasteboard.getContents()

    if not selectedText or selectedText == "" or selectedText == oldClipboard then
      showSteady("No text selected", COLOR_AMBER)
      hidePillAfter(1.2)
      return
    end

    showProcessing()

    local requestBody = hs.json.encode({ text = selectedText })

    hs.task.new(M.config.curlPath, function(exitCode, stdOut, stdErr)
      if exitCode ~= 0 then
        print(string.format("Echo rewrite: curl exit=%s stderr=%s", tostring(exitCode), stdErr or "(none)"))
        showSteady("Rewrite failed", COLOR_RED)
        hidePillAfter(1.4)
        return
      end

      local ok, decoded = pcall(hs.json.decode, stdOut)
      if not ok or not decoded or not decoded.text then
        print(string.format("Echo rewrite: bad response body=%s", stdOut or "(empty)"))
        showSteady("Bad response", COLOR_RED)
        hidePillAfter(1.4)
        return
      end

      -- Put polished text in clipboard — user pastes with Cmd+V
      hs.pasteboard.setContents(decoded.text)
      showSteady("Cmd+V to paste", COLOR_GREEN)
      hidePillAfter(2.5)
    end, {
      "-s", "-S", "-X", "POST",
      M.config.apiUrl .. "/rewrite",
      "-H", "x-api-key: " .. M.config.apiKey,
      "-H", "Content-Type: application/json",
      "-d", requestBody,
    }):start()
  end)
end

--------------------------------------------------------------------------
-- Voice recording: hold Fn to record, release to transcribe
--------------------------------------------------------------------------

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
  if rewriteHotkey then
    rewriteHotkey:delete()
  end
  -- Delete old orb canvas so ensureOrb() creates a fresh one with the
  -- current design (important when the HUD layout changes between versions).
  stopAnimation()
  if orb then
    orb:delete()
    orb = nil
  end
  layerParams = nil
  waveParams = nil

  -- Fn key: hold to record voice
  fnWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, handleFlagsChanged)
  fnWatcher:start()

  -- Cmd+Shift+R: rewrite selected text
  rewriteHotkey = hs.hotkey.bind({"cmd", "shift"}, "r", rewriteSelectedText)
end

return M

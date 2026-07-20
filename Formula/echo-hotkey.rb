class EchoHotkey < Formula
  desc "Echo voice dictation Mac hotkey (Hammerspoon script + auto-updater)"
  homepage "https://github.com/joyinfant99/echo"
  url "https://github.com/joyinfant99/homebrew-echo.git", branch: "main"
  version "2026.07.20.24"
  license "MIT"
  head "https://github.com/joyinfant99/homebrew-echo.git", branch: "main"

  depends_on "sox"

  def install
    prefix.install "echo.lua"
    prefix.install "echo_config.lua.example"
  end

  def post_install
    # Formulas can't depend_on a cask directly, so install Hammerspoon here
    # if it's missing rather than making the user do it as a separate step.
    unless File.directory?("/Applications/Hammerspoon.app")
      system HOMEBREW_BREW_FILE.to_s, "install", "--cask", "hammerspoon"
    end

    hammerspoon_dir = Pathname.new(Dir.home)/".hammerspoon"
    hammerspoon_dir.mkpath
    File.write(hammerspoon_dir/"BREW_TEST_MARKER.txt", "written at #{Time.now}")

    cp prefix/"echo.lua", hammerspoon_dir/"echo.lua"

    config_path = hammerspoon_dir/"echo_config.lua"
    cp prefix/"echo_config.lua.example", config_path unless config_path.exist?

    init_lua = hammerspoon_dir/"init.lua"
    init_lua.write("") unless init_lua.exist?
    unless init_lua.read.include?('require("echo")')
      init_lua.open("a") { |f| f.puts('require("echo").start()') }
    end

    # Reload Hammerspoon if it's already running (picks up the new script),
    # otherwise launch it for the first time.
    if system("pgrep", "-q", "Hammerspoon")
      system "osascript", "-e", 'tell application "Hammerspoon" to quit'
      sleep 1
    end
    system "open", "-a", "Hammerspoon"
  end

  # Homebrew's own service mechanism, not a hand-written plist: writing
  # directly to ~/Library/LaunchAgents from inside post_install gets
  # silently redirected by Homebrew's install sandbox (confirmed empirically
  # — the file never reaches the real path). `brew services` runs outside
  # that sandbox and is the supported way to register a periodic LaunchAgent.
  service do
    run ["/bin/bash", "-c", "#{HOMEBREW_PREFIX}/bin/brew update && #{HOMEBREW_PREFIX}/bin/brew upgrade echo-hotkey"]
    run_type :interval
    interval 21600
    log_path (var/"log/echo-updater.log").to_s
    error_log_path (var/"log/echo-updater.log").to_s
  end

  def caveats
    <<~EOS
      One-time setup still needed (can't be automated):
        1. Edit ~/.hammerspoon/echo_config.lua with your real backend URL
           and API key.
        2. Grant Hammerspoon Microphone + Accessibility permissions when
           macOS prompts (System Settings -> Privacy & Security) -- this
           happens on your first recording, not on install.
        3. System Settings -> Keyboard -> "Press Fn key to" -> Do Nothing.
        4. Run `brew services start echo-hotkey` once, to turn on
           automatic background updates (checks every 6 hours).

      After that: hold Fn anywhere, speak, release. Updates apply
      themselves automatically in the background -- you should never need
      to run `brew upgrade` by hand again.
    EOS
  end

  test do
    assert_predicate prefix/"echo.lua", :exist?
  end
end

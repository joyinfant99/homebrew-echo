class EchoHotkey < Formula
  desc "Echo voice dictation Mac hotkey (Hammerspoon script + auto-updater)"
  homepage "https://github.com/joyinfant99/echo"
  url "https://github.com/joyinfant99/homebrew-echo.git", branch: "main"
  version "2026.07.20.1"
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

    install_updater_launch_agent
  end

  def install_updater_launch_agent
    agents_dir = Pathname.new(Dir.home)/"Library/LaunchAgents"
    agents_dir.mkpath
    plist_path = agents_dir/"com.echo.updater.plist"

    plist_path.write <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>com.echo.updater</string>
        <key>ProgramArguments</key>
        <array>
          <string>/bin/bash</string>
          <string>-c</string>
          <string>#{HOMEBREW_PREFIX}/bin/brew update &amp;&amp; #{HOMEBREW_PREFIX}/bin/brew upgrade echo-hotkey</string>
        </array>
        <key>StartInterval</key>
        <integer>21600</integer>
        <key>RunAtLoad</key>
        <false/>
        <key>StandardOutPath</key>
        <string>#{Dir.home}/Library/Logs/echo-updater.log</string>
        <key>StandardErrorPath</key>
        <string>#{Dir.home}/Library/Logs/echo-updater.log</string>
      </dict>
      </plist>
    EOS

    quiet_system "launchctl", "unload", plist_path.to_s
    system "launchctl", "load", plist_path.to_s
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

      After that: hold Fn anywhere, speak, release. Updates apply
      themselves automatically in the background every 6 hours via a
      LaunchAgent -- you should never need to run `brew upgrade` by hand.
    EOS
  end

  test do
    assert_predicate prefix/"echo.lua", :exist?
  end
end

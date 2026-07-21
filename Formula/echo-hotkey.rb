class EchoHotkey < Formula
  desc "Echo voice dictation Mac hotkey (Hammerspoon script + auto-updater)"
  homepage "https://github.com/joyinfant99/echo"
  url "https://github.com/joyinfant99/homebrew-echo.git", branch: "main"
  version "2026.07.21.51"
  license "MIT"
  head "https://github.com/joyinfant99/homebrew-echo.git", branch: "main"

  depends_on "sox"

  def install
    prefix.install "echo.lua"
    prefix.install "echo_config.lua.example"
    bin.install "bin/echo-sync"
  end

  # post_install deliberately does nothing to ~/.hammerspoon or
  # ~/Library/LaunchAgents: Homebrew's install/post_install sandbox silently
  # blocks writes anywhere under $HOME (confirmed empirically — a plain
  # marker-file write never reached the real path, no error, nothing). Every
  # bit of actual file placement + Hammerspoon reload happens in bin/echo-sync
  # instead, which only ever runs via launchd (through `brew services`),
  # a process tree the sandbox doesn't touch.

  service do
    run [bin/"echo-sync"]
    run_type :interval
    interval 21600
    log_path (var/"log/echo-updater.log").to_s
    error_log_path (var/"log/echo-updater.log").to_s
  end

  def caveats
    <<~EOS
      Run this once to finish setup and turn on automatic background updates
      (checks every 6 hours from then on):

        brew services start echo-hotkey

      That first run also creates ~/.hammerspoon/echo_config.lua for you --
      edit it with your real backend URL and API key. Then:
        - Grant Hammerspoon Microphone + Accessibility permissions when
          macOS prompts (System Settings -> Privacy & Security) -- happens
          on your first recording, not on install.
        - System Settings -> Keyboard -> "Press Fn key to" -> Do Nothing.

      After that: hold Fn anywhere, speak, release. You should never need
      to run `brew upgrade` or touch any files by hand again.
    EOS
  end

  test do
    assert_predicate prefix/"echo.lua", :exist?
    assert_predicate bin/"echo-sync", :exist?
  end
end

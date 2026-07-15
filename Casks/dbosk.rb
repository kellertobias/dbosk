# Homebrew cask for dbOSK. This repo doubles as its own tap:
#
#   brew tap kellertobias/dbosk https://github.com/kellertobias/dbosk
#   brew install --cask kellertobias/dbosk/dbosk
#
# No prebuilt artifact is published: the cask downloads the main branch and
# compiles the app locally in preflight, then the `app` stanza installs the
# result to /Applications.
cask "dbosk" do
  version :latest
  sha256 :no_check

  url "https://github.com/kellertobias/dbosk/archive/refs/heads/main.tar.gz"
  name "dbOSK"
  desc "Native database client for PostgreSQL, MySQL/MariaDB, MongoDB, and SQLite"
  homepage "https://github.com/kellertobias/dbosk"

  depends_on macos: :sonoma

  app "dbosk-main/dist/dbOSK.app"
  binary "#{appdir}/dbOSK.app/Contents/MacOS/dbOSK", target: "dbosk"

  preflight do
    source = staged_path/"dbosk-main"
    system_command "/bin/bash",
                   args:         [(source/"Scripts/make-app.sh").to_s],
                   print_stdout: true
  end

  zap trash: "~/Library/Preferences/dev.tobiaskeller.dbosk.plist"

  caveats <<~EOS
    dbOSK was compiled locally from the main branch. Building requires
    Xcode 16+ and network access for SwiftPM dependencies.

    The build is ad-hoc signed and not notarized. The executable is compiled
    locally and carries no quarantine attribute, so the app normally launches
    without a Gatekeeper prompt. Should macOS block the first launch anyway,
    approve it once via right-click -> Open, or under
    System Settings -> Privacy & Security -> "Open Anyway".

    `brew upgrade` cannot detect new commits (version :latest); update with:
      brew reinstall --cask dbosk
  EOS
end

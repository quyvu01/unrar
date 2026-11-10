# Homebrew cask for Unrar. This repository doubles as a tap:
#
#   brew tap quyvu01/unrar https://github.com/quyvu01/unrar
#   brew install --cask unrar-app
#
# The zip is built and published by .github/workflows/build.yml on every push to main.
cask "unrar-app" do
  version :latest
  sha256 :no_check

  url "https://github.com/quyvu01/unrar/releases/latest/download/Unrar.zip"
  name "Unrar"
  desc "Modern archive extractor for RAR, ZIP, 7z, TAR, GZ, BZ2, XZ and more"
  homepage "https://github.com/quyvu01/unrar"

  depends_on macos: ">= :sonoma"

  app "Unrar.app"

  # The app is signed ad hoc (not notarized), so drop the quarantine flag that
  # would otherwise make Gatekeeper refuse to open it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Unrar.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/io.github.quyvu01.unrar.plist",
    "~/Library/Saved Application State/io.github.quyvu01.unrar.savedState",
  ]
end

cask "bettercapture" do
  version "1.0.0"
  sha256 :no_check # Updated automatically by release workflow

  url "https://github.com/jsattler/BetterCapture/releases/download/v#{version}/BetterCapture-#{version}-arm64.dmg"
  name "BetterCapture"
  desc "The macOS screen recorder you deserve - always free and open source"
  homepage "https://github.com/jsattler/BetterCapture"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "BetterCapture.app"

  zap trash: [
    "~/Library/Application Support/BetterCapture",
    "~/Library/Caches/com.sattlerjoshua.BetterCapture",
    "~/Library/Preferences/com.sattlerjoshua.BetterCapture.plist",
  ]
end

require "json"
require "pathname"

class Pragma < Formula
  desc "Lightweight CLI wrapper that runs codex sub-agents"
  homepage "https://github.com/tkersey/pragma"

  METADATA = begin
    metadata_path = Pathname(__dir__).join("pragma.json")
    metadata_path.exist? ? JSON.parse(metadata_path.read) : {}
  end.freeze

  if (macos = METADATA["macos"]) && macos["url"] && macos["sha256"] && METADATA["version"]
    version METADATA["version"]
    url macos["url"]
    sha256 macos["sha256"]
  end

  head "https://github.com/tkersey/pragma.git", branch: "main"

  depends_on "zig" => :build unless METADATA.dig("macos", "url")

  def install
    if build.head? || self.class::METADATA.dig("macos", "url").nil?
      system "zig", "build", "-Doptimize=ReleaseFast"
      bin.install "zig-out/bin/pragma"
    else
      bin.install "pragma-macos/pragma"
      bin.install "pragma-macos/pragma-scorecard"
    end
  end

  test do
    output = shell_output("#{bin}/pragma 2>&1")
    assert_match "usage: pragma", output
  end
end

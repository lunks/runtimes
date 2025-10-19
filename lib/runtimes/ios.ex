defmodule Runtimes.Ios do
  import Runtimes

  def architectures() do
    # armv7 (32-bit) removed - not supported in modern iOS SDKs (iOS 11+ requires 64-bit)
    %{
      "ios-arm64" => %{
        arch: "arm64",
        id: "ios64",
        sdk: "iphoneos",
        openssl_arch: "ios64-xcrun",
        xcomp: "arm64-ios",
        name: "aarch64-apple-ios",
        cflags: "-mios-version-min=7.0.0 -fno-common -Os -D__IOS__=yes"
      },
      "iossimulator-x86_64" => %{
        arch: "x86_64",
        id: "iossimulator",
        sdk: "iphonesimulator",
        openssl_arch: "iossimulator-x86_64-xcrun",
        xcomp: "x86_64-iossimulator",
        name: "x86_64-apple-iossimulator",
        cflags: "-mios-simulator-version-min=7.0.0 -fno-common -Os -D__IOS__=yes"
      },
      "iossimulator-arm64" => %{
        arch: "arm64",
        id: "iossimulator",
        sdk: "iphonesimulator",
        openssl_arch: "iossimulator-arm64-xcrun",
        xcomp: "arm64-iossimulator",
        name: "aarch64-apple-iossimulator",
        cflags: "-mios-simulator-version-min=7.0.0 -fno-common -Os -D__IOS__=yes"
      }
    }
  end

  def get_arch(arch) do
    Map.fetch!(architectures(), arch)
  end

  # lipo joins different cpu build of the same target together
  def lipo([]), do: []
  def lipo([one]), do: [one]

  def lipo(more) do
    File.mkdir_p!("tmp")
    tmp = "tmp/liberlang.a"
    if File.exists?(tmp), do: File.rm!(tmp)
    cmd("lipo -create #{Enum.join(more, " ")} -output #{tmp}")
    [tmp]
  end
end

defmodule Mix.Tasks.Package.Ios.Runtime do
  import Runtimes.Ios
  import Runtimes
  alias Mix.Tasks.Package.Ios.Nif
  use Mix.Task
  require EEx

  def run(["with_diode_nifs"]) do
    nifs = [
      "https://github.com/diodechain/esqlite.git",
      "https://github.com/diodechain/libsecp256k1.git"
    ]

    run(nifs)
  end

  def run([]) do
    run(["https://github.com/elixir-desktop/exqlite"])
  end

  def run(nifs) do
    IO.puts("Validating nifs...")
    Enum.each(nifs, fn nif -> Runtimes.get_nif(nif) end)
    buildall(Map.keys(architectures()), nifs)
  end

  def build(archid, extra_nifs) do
    arch = get_arch(archid)
    File.mkdir_p!("_build/#{arch.name}")

    # Building OpenSSL
    if File.exists?(openssl_lib(arch)) do
      IO.puts("OpenSSL (#{arch.id}) already exists...")
    else
      cmd("scripts/install_openssl.sh",
        ARCH: arch.openssl_arch,
        OPENSSL_PREFIX: openssl_target(arch),
        MAKEFLAGS: "-j10 -O"
      )
    end

    # Building OTP
    if File.exists?(runtime_target(arch)) do
      IO.puts("liberlang.a (#{arch.id}) already exists...")
    else
      if !File.exists?(otp_target(arch)) do
        Runtimes.ensure_otp()
        cmd(~w(git clone _build/otp #{otp_target(arch)}))

        # Apply iOS-specific patches

        # Patch 1: DED_LD linker fix
        # Upstream OTP uses DED_LD=$LD (raw linker) in iOS xcomp configs.
        # Modern Xcode toolchains pass -fstack-protector-strong which ld doesn't understand.
        # This patch changes DED_LD to use 'xcrun cc' (compiler frontend) instead.
        # Verified needed for OTP 26.2.5.6, 27.3, and 28.1.
        ded_ld_patch = Path.absname("patch/otp-ios-ded-ld-fix.patch")
        if File.exists?(ded_ld_patch) do
          cmd("cd #{otp_target(arch)} && git apply #{ded_ld_patch}")
        end

        # Patch 2: zlib fdopen macro fix (OTP 26 and 27 only)
        # OTP's embedded zlib defines fdopen as a macro which conflicts with iOS 18.5 SDK.
        # The macro `#define fdopen(fd,mode) NULL` collides with system fdopen() declaration.
        # This patch prevents the macro definition on Apple platforms.
        # Note: OTP 28+ uses a newer zlib version without this issue, so patch only applies to OTP 26/27.
        zlib_patch = Path.absname("patch/otp-ios-zlib-fdopen-fix.patch")
        if File.exists?(zlib_patch) do
          # Check if patch applies before attempting (OTP 28+ doesn't need it)
          case System.cmd("sh", ["-c", "cd #{otp_target(arch)} && git apply --check #{zlib_patch}"], stderr_to_stdout: true) do
            {_, 0} ->
              IO.puts("Applying zlib fdopen patch...")
              cmd("cd #{otp_target(arch)} && git apply #{zlib_patch}")
            {_, _} ->
              IO.puts("Skipping zlib fdopen patch (not needed for this OTP version)")
          end
        end
      end

      env = [
        LIBS: openssl_lib(arch),
        INSTALL_PROGRAM: "/usr/bin/install -c",
        MAKEFLAGS: "-j10 -O",
        RELEASE_LIBBEAM: "yes"
      ]

      if System.get_env("SKIP_CLEAN_BUILD") == nil do
        nifs = [
          "#{otp_target(arch)}/lib/asn1/priv/lib/#{arch.name}/asn1rt_nif.a",
          "#{otp_target(arch)}/lib/crypto/priv/lib/#{arch.name}/crypto.a"
        ]

        # First round build to generate headers and libs required to build nifs:
        cmd(
          ~w(
          cd #{otp_target(arch)} &&
          git clean -xdf &&
          ./otp_build setup
          --with-ssl=#{openssl_target(arch)}
          --disable-dynamic-ssl-lib
          --xcomp-conf=xcomp/erl-xcomp-#{arch.xcomp}.conf
          --enable-static-nifs=#{Enum.join(nifs, ",")}
        ),
          env
        )

        cmd(~w(cd #{otp_target(arch)} && ./otp_build boot -a), env)
        cmd(~w(cd #{otp_target(arch)} && ./otp_build release -a), env)
      end

      # Second round
      # The extra path can only be generated AFTER the nifs are compiled
      # so this requires two rounds...
      extra_nifs =
        Enum.map(extra_nifs, fn nif ->
          if static_lib_path(arch, Runtimes.get_nif(nif)) == nil do
            Nif.build(archid, nif)
          end

          static_lib_path(arch, Runtimes.get_nif(nif))
          |> Path.absname()
        end)

      nifs = [
        "#{otp_target(arch)}/lib/asn1/priv/lib/#{arch.name}/asn1rt_nif.a",
        "#{otp_target(arch)}/lib/crypto/priv/lib/#{arch.name}/crypto.a"
        | extra_nifs
      ]

      cmd(
        ~w(
          cd #{otp_target(arch)} && ./otp_build configure
          --with-ssl=#{openssl_target(arch)}
          --disable-dynamic-ssl-lib
          --xcomp-conf=xcomp/erl-xcomp-#{arch.xcomp}.conf
          --enable-static-nifs=#{Enum.join(nifs, ",")}
        ),
        env
      )

      cmd(~w(cd #{otp_target(arch)} && ./otp_build boot -a), env)
      cmd(~w(cd #{otp_target(arch)} && ./otp_build release -a), env)

      {build_host, 0} = System.cmd("#{otp_target(arch)}/erts/autoconf/config.guess", [])
      build_host = String.trim(build_host)

      # [erts_version] = Regex.run(~r/erts-[^ ]+/, File.read!("otp/otp_versions.table"))
      # Locating all built .a files for the target architecture:
      files =
        :filelib.fold_files(
          String.to_charlist(otp_target(arch)),
          ~c".+\\.a$",
          true,
          fn name, acc ->
            name = List.to_string(name)

            if String.contains?(name, arch.name) and
                 not (String.contains?(name, build_host) or
                        String.ends_with?(name, "_st.a") or String.ends_with?(name, "_r.a")) do
              Map.put(acc, Path.basename(name), name)
            else
              acc
            end
          end,
          %{}
        )
        |> Map.values()

      files = files ++ [openssl_lib(arch) | nifs]

      # Creating a new archive
      repackage_archive("libtool", files, runtime_target(arch))
    end
  end

  defp buildall(targets, nifs) do
    Runtimes.ensure_otp()

    # targets
    # |> Enum.map(fn target -> Task.async(fn -> build(target, nifs) end) end)
    # |> Enum.map(fn task -> Task.await(task, 60_000*60*3) end)
    if System.get_env("PARALLEL", "") != "" do
      for target <- targets do
        {spawn_monitor(fn -> build(target, nifs) end), target}
      end
      |> Enum.each(fn {{pid, ref}, target} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} ->
            :ok

          {:DOWN, ^ref, :process, ^pid, reason} ->
            IO.puts("Build failed for #{target}: #{inspect(reason)}")
            raise reason
        end
      end)
    else
      for target <- targets do
        build(target, nifs)
      end
    end

    {sims, reals} =
      Enum.map(targets, fn target -> runtime_target(get_arch(target)) end)
      |> Enum.split_with(fn lib -> String.contains?(lib, "simulator") end)

    libs =
      (lipo(sims) ++ lipo(reals))
      |> Enum.map(fn lib -> "-library #{lib}" end)

    # Extract OTP major version for framework name (e.g., "OTP-28.1" -> "otp-28")
    otp_tag = Runtimes.otp_tag()
    otp_version =
      case Regex.run(~r/OTP-(\d+)/, otp_tag) do
        [_, major] -> "otp-#{major}"
        _ -> "otp"
      end

    framework = "./_build/liberlang-#{otp_version}.xcframework"

    if File.exists?(framework) do
      File.rm_rf!(framework)
    end

    cmd(
      "xcodebuild -create-xcframework -output #{framework} " <>
        Enum.join(libs, " ")
    )
  end
end

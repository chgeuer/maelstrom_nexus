defmodule Mix.Tasks.MaelstromNexus.Setup do
  @moduledoc """
  Downloads and extracts the Maelstrom test framework.

  Fetches the Maelstrom release archive from GitHub and extracts it into a
  `.maelstrom/` directory inside your project root. This directory is
  automatically added to `.gitignore`.

  ## Usage

      mix maelstrom_nexus.setup

  ## Options

  - `--version` — Maelstrom version to download (default: `v0.2.4`)
  - `--path` — extraction directory (default: `.maelstrom`)
  - `--force` — re-download even if already present

  ## After setup

  The Maelstrom binary will be at `.maelstrom/maelstrom/maelstrom` and the
  jar at `.maelstrom/maelstrom/lib/maelstrom.jar`. Use the binary to run
  workload tests:

      .maelstrom/maelstrom/maelstrom test -w echo \\
        --bin ./bin/my_node \\
        --node-count 1 \\
        --time-limit 10
  """

  use Mix.Task

  @shortdoc "Downloads the Maelstrom test framework"

  @default_version "v0.2.4"
  @default_path ".maelstrom"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [version: :string, path: :string, force: :boolean]
      )

    version = Keyword.get(opts, :version, @default_version)
    base_path = Keyword.get(opts, :path, @default_path)
    force? = Keyword.get(opts, :force, false)

    maelstrom_bin = Path.join([base_path, "maelstrom", "maelstrom"])
    maelstrom_jar = Path.join([base_path, "maelstrom", "lib", "maelstrom.jar"])

    if not force? and File.exists?(maelstrom_bin) and File.exists?(maelstrom_jar) do
      Mix.shell().info("✓ Maelstrom already present at #{maelstrom_bin}")
      :ok
    else
      url =
        "https://github.com/jepsen-io/maelstrom/releases/download/#{version}/maelstrom.tar.bz2"

      Mix.shell().info("⬇ Downloading Maelstrom #{version}...")
      Mix.shell().info("  #{url}")

      File.mkdir_p!(base_path)

      {_, exit_code} =
        System.cmd("curl", ["-fsSL", url],
          into: File.stream!(Path.join(base_path, "maelstrom.tar.bz2"))
        )

      if exit_code != 0 do
        Mix.raise("Failed to download Maelstrom #{version}")
      end

      Mix.shell().info("📦 Extracting...")

      {_, exit_code} =
        System.cmd("tar", ["xjf", "maelstrom.tar.bz2"], cd: base_path)

      if exit_code != 0 do
        Mix.raise("Failed to extract Maelstrom archive")
      end

      File.rm(Path.join(base_path, "maelstrom.tar.bz2"))

      File.chmod!(maelstrom_bin, 0o755)

      ensure_gitignored(base_path)

      Mix.shell().info("✓ Maelstrom #{version} installed at #{maelstrom_bin}")
      :ok
    end
  end

  defp ensure_gitignored(path) do
    gitignore = ".gitignore"
    pattern = "/#{path}"

    if File.exists?(gitignore) do
      content = File.read!(gitignore)

      unless String.contains?(content, pattern) do
        File.write!(
          gitignore,
          content <>
            "\n# Maelstrom test framework (fetched by mix maelstrom_nexus.setup)\n#{pattern}/\n"
        )

        Mix.shell().info("  Added #{pattern}/ to .gitignore")
      end
    else
      File.write!(
        gitignore,
        "# Maelstrom test framework (fetched by mix maelstrom_nexus.setup)\n#{pattern}/\n"
      )

      Mix.shell().info("  Created .gitignore with #{pattern}/")
    end
  end
end

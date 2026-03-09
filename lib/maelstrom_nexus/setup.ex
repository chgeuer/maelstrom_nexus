defmodule MaelstromNexus.Setup do
  @moduledoc """
  Helpers for locating the Maelstrom installation.

  After running `mix maelstrom_nexus.setup`, use these functions to find
  paths to the Maelstrom binary and jar.
  """

  @default_base_path ".maelstrom"

  @doc """
  Returns the path to the Maelstrom binary.

  Raises if Maelstrom is not installed. Run `mix maelstrom_nexus.setup` first.
  """
  @spec bin_path(String.t()) :: String.t()
  def bin_path(base_path \\ @default_base_path) do
    path = Path.join([base_path, "maelstrom", "maelstrom"])

    unless File.exists?(path) do
      raise "Maelstrom not found at #{path}. Run: mix maelstrom_nexus.setup"
    end

    path
  end

  @doc """
  Returns the path to the Maelstrom jar.

  Raises if Maelstrom is not installed. Run `mix maelstrom_nexus.setup` first.
  """
  @spec jar_path(String.t()) :: String.t()
  def jar_path(base_path \\ @default_base_path) do
    path = Path.join([base_path, "maelstrom", "lib", "maelstrom.jar"])

    unless File.exists?(path) do
      raise "Maelstrom jar not found at #{path}. Run: mix maelstrom_nexus.setup"
    end

    path
  end

  @doc """
  Returns `true` if Maelstrom is installed at the given path.
  """
  @spec installed?(String.t()) :: boolean()
  def installed?(base_path \\ @default_base_path) do
    bin = Path.join([base_path, "maelstrom", "maelstrom"])
    jar = Path.join([base_path, "maelstrom", "lib", "maelstrom.jar"])
    File.exists?(bin) and File.exists?(jar)
  end
end

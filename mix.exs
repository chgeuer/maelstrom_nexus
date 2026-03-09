defmodule MaelstromNexus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/chgeuer/maelstrom_nexus"

  def project do
    [
      app: :maelstrom_nexus,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "MaelstromNexus",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A multi-process Maelstrom protocol library for Elixir.
    Designed for consensus engines and complex distributed systems
    that need cross-process message coordination through Maelstrom's
    stdin/stdout JSON protocol.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "usage_rules.md"]
    ]
  end
end

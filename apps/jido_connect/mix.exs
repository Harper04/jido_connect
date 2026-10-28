defmodule JidoConnectCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_connect,
      version: "0.9.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      source_url: "https://github.com/agentjido/jido_connect",
      test_coverage: test_coverage(),
      test_ignore_filters: [~r/test\/support\//],
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Jido.Connect.Application, []},
      extra_applications: [:logger],
      env: [jido_connect_providers: [Jido.Connect.MCP]]
    ]
  end

  def cli do
    [
      preferred_envs: [
        q: :test,
        quality: :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jido,
       git: "https://github.com/agentjido/jido.git",
       ref: "aaca071c90691662c7036fe4d71ab63e6ee3432a",
       override: true},
      {:jido_action,
       git: "https://github.com/agentjido/jido_action.git",
       ref: "d2a981895fb986e9a2fe88f8c523326572643117",
       override: true},
      {:jido_ai,
       git: "https://github.com/agentjido/jido_ai.git",
       ref: "3b02d83eaa248e262ba1760f39da73cab5fe3bdf"},
      {:jido_signal,
       git: "https://github.com/agentjido/jido_signal.git",
       ref: "7b825f1d050a0e0159bb2a72ba79c100b5d362d3",
       override: true},
      {:arbor_mcp, "== 2.0.0-rc.6"},
      {:ex_doc, "~> 0.40", only: :docs, runtime: false},
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:splode, "~> 0.3.0"},
      {:spark, "~> 2.7"},
      {:telemetry, "~> 1.3"},
      {:zoi,
       git: "https://github.com/mikehostetler/zoi.git",
       ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
       override: true}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --cover"
      ]
    ]
  end

  defp description do
    "Spark DSL and runtime contracts for compiling integration packages into Jido actions, sensors, and plugins."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/agentjido/jido_connect",
        "Docs" => "https://hexdocs.pm/jido_connect"
      },
      files: ~w(lib guides mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/mcp_bridge.md",
        "guides/authoring_connector.md",
        "CHANGELOG.md"
      ],
      source_ref: "release/3.0"
    ]
  end

  defp test_coverage do
    [
      summary: [threshold: 80],
      ignore_modules: [
        ~r/^Jido\.Connect\.Dsl(\.|$)/,
        ~r/^Jido\.Connect\.Dev\./,
        ~r/^Jido\.Connect\.Error\.(Auth|Config|Execution|Internal|Invalid|Provider)$/,
        ~r/^Mix\.Tasks\./
      ]
    ]
  end
end

defmodule JidoConnect.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.9.0",
      start_permanent: Mix.env() == :prod,
      name: "Jido Connect",
      source_url: "https://github.com/agentjido/jido_connect",
      docs: docs(),
      deps: deps(),
      aliases: aliases()
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

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
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
      {:zoi,
       git: "https://github.com/mikehostetler/zoi.git",
       ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
       override: true},
      {:ex_doc, "~> 0.40", only: :docs, runtime: false}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      quality: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "usage-rules.md",
        "apps/jido_connect/guides/authoring_connector.md",
        "apps/jido_connect/guides/mcp_bridge.md",
        "docs/architecture.md",
        "docs/authoring_integrations.md",
        "docs/catalog_packs.md",
        "docs/generated_jido_modules.md",
        "docs/google_connector_conventions.md",
        "docs/google_extension_patterns.md",
        "docs/google_polling_checkpoints.md",
        "docs/google_scope_audit.md",
        "docs/host_owned_storage.md",
        "docs/jido_connect_ecosystem_migration.md",
        "docs/github_auth.md",
        "docs/github_webhooks.md",
        "docs/github_end_to_end.md",
        "docs/slack_auth.md",
        "docs/release_checklist.md"
      ],
      groups_for_extras: [
        Guides: ~r/docs\/.*/
      ]
    ]
  end
end

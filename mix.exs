defmodule Tymeslot.MixProject do
  use Mix.Project

  def project do
    [
      app: :tymeslot,
      version: "0.99.37",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      build_path: build_path(),
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"],
      releases: [
        tymeslot: [
          applications: [tymeslot: :permanent]
        ]
      ],
      test_coverage: [tool: ExCoveralls],
      licenses: ["Elastic-2.0"],
      links: %{
        "License" => "https://www.elastic.co/licensing/elastic-license"
      }
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.cobertura": :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.lcov": :test,
        "coveralls.post": :test,
        "coveralls.xml": :test
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Tymeslot.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  # Use the umbrella root's _build when running inside the umbrella,
  # fall back to the local _build for standalone (self-hosted) deployments.
  defp build_path do
    umbrella_root = Path.join(__DIR__, "../..")

    if File.exists?(Path.join(umbrella_root, "mix.exs")) do
      Path.join(umbrella_root, "_build")
    else
      "_build"
    end
  end

  defp elixirc_paths(:dev), do: ["lib"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:tidewave, "~> 0.5", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, "~> 0.1.8", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.19"},
      {:finch, "~> 0.20"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2"},
      {:bandit, "~> 1.8"},
      {:caldav_client, "~> 2.0"},
      {:webdavex, "~> 0.3.3"},
      {:tz, "~> 0.28"},
      {:uuid, "~> 1.1"},
      {:bcrypt_elixir, "~> 3.2"},
      {:oauth2, "~> 2.1"},
      {:mox, "~> 1.0", only: :test},
      {:meck, "~> 1.1", only: :test},
      {:ex_machina, "~> 2.8", only: :test},
      {:stripity_stripe, "~> 3.2.0"},
      {:hammer, "~> 7.1"},
      {:html_sanitize_ex, "~> 1.4"},
      {:gen_smtp, "~> 1.2"},
      {:castore, "~> 1.0"},
      {:mjml, "~> 5.2"},
      {:nodejs, "~> 3.0"},
      {:oban, "~> 2.20"},
      {:logger_json, "~> 7.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:magical, "~> 1.0"},
      {:nimble_parsec, "~> 1.4"},
      {:ex_image_info, "~> 1.0"},
      {:sweet_xml, "~> 0.7"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "1.7.17", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:flagpack, "~> 0.6"},
      # Plug for setting conn.remote_ip from proxy headers
      {:remote_ip, "~> 1.1"},
      {:stream_data, "~> 1.1", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:phoenix_ecto, "~> 4.6", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "tailwind tymeslot",
        "tailwind quill",
        "tailwind rhythm",
        "esbuild tymeslot",
        "esbuild bundles",
        "esbuild embed",
        "esbuild iframe_embed"
      ],
      "assets.deploy": [
        "tailwind tymeslot --minify",
        "tailwind quill --minify",
        "tailwind rhythm --minify",
        "esbuild tymeslot --minify",
        "esbuild bundles --minify",
        "esbuild embed --minify",
        "esbuild iframe_embed --minify",
        "phx.digest"
      ]
    ]
  end
end

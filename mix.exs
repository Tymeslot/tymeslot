defmodule Tymeslot.MixProject do
  use Mix.Project

  def project do
    [
      app: :tymeslot,
      version: "1.13.1",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      build_path: "_build",
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      gettext: [
        # Reference comments keep the file but drop the line number. A line
        # number is invalidated by any edit above the call, so with it on, every
        # refactor, extraction or reformat leaves the catalogues stale and needs
        # a re-extract commit carrying no information. Without it, references
        # change only when a message is added, removed, or moved between files,
        # which is the part a translator can act on.
        write_reference_line_numbers: false
      ],
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        # Surfaces filters in .dialyzer_ignore.exs that no longer match, so
        # suppressions cannot outlive the warning they were added for.
        list_unused_filters: true,
        # Include Mix and Credo so Dialyzer knows about their behaviours and
        # modules; the custom checks under dev_support/ implement Credo's.
        # Dialyxir is here for the same reason: it is `runtime: false`, so
        # `plt_add_deps: :app_tree` leaves it out, and `mix dialyzer.incremental`
        # calls into it. Without it every one of those calls is reported as a
        # call to a function that does not exist.
        plt_add_apps: [:mix, :credo, :dialyxir],
        # Analyse against the full runtime dependency tree rather than the
        # direct deps alone, so cross-dependency contract errors are caught.
        plt_add_deps: :app_tree,
        # xmerl (pulled in by sweet_xml) has warn_missing_spec in its OTP 28
        # BEAMs. PLT-construction warnings bypass dialyxir's filter, so we
        # exclude xmerl from the PLT entirely. Sweet_xml's own specs are
        # sufficient for our analysis.
        plt_ignore_apps: [:xmerl],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        flags: [:error_handling]
      ],
      releases: [
        tymeslot: [
          applications: [tymeslot: :permanent]
        ]
      ],
      test_coverage: [tool: ExCoveralls],
      licenses: ["AGPL-3.0-or-later"],
      links: %{
        "License" => "https://www.gnu.org/licenses/agpl-3.0.html"
      }
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.e2e": :test,
        "test.affected": :test,
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
  defp elixirc_paths(:dev), do: ["lib", "dev/support"]
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
      {:phoenix_live_view, "~> 1.1"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, "~> 0.1.8", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.1", runtime: Mix.env() == :dev},
      # 1.27 is the first release carrying the AhaSend adapter.
      {:swoosh, "~> 1.27"},
      # Required by Swoosh's Mailgun adapter (multipart request bodies).
      {:multipart, "~> 0.4"},
      {:finch, "~> 0.20"},
      {:req, "~> 0.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3"},
      {:dotenvy, "~> 1.1"},
      {:bandit, "~> 1.8"},
      {:tz, "~> 0.28"},
      {:uuid, "~> 1.1"},
      {:bcrypt_elixir, "~> 3.2"},
      {:oauth2, "~> 2.1"},
      {:mox, "~> 1.0", only: :test},
      {:meck, "~> 1.1", only: :test},
      {:ex_machina, "~> 2.8", only: :test},
      {:stripity_stripe, "~> 3.3"},
      # Pinned to 4.x, which every remaining requirement accepts: Swoosh
      # and Tesla declare it optional, Wallaby's httpoison and
      # web_driver_client are test-only, and stripity_stripe uses hackney
      # as its non-optional HTTP client for every Stripe API call.
      # hackney 4.x has two real runtime consumers: Swoosh's Postmark
      # adapter (config :swoosh, :api_client, Swoosh.ApiClient.Hackney,
      # prod-only) and stripity_stripe. Neither path is exercised in CI
      # (test config uses Swoosh.Adapters.Test and Stripe is mocked), so
      # both need verification in staging after any hackney upgrade.
      # The same override must be repeated in any project that depends on
      # this one as a path dependency, because overrides declared by a
      # dependency do not apply to the parent project's resolution.
      # Verified via `mix deps.tree`/mix.lock: no current dependency
      # requires hackney below 4.0 (stripity_stripe's own requirement is
      # already the non-optional `~> 4.0` that would be picked without this
      # override), so nothing is being resolved here today. Retained
      # deliberately as a guard against a future dependency reintroducing a
      # lower requirement and silently downgrading hackney underneath it.
      {:hackney, "~> 4.0", override: true},
      {:hammer, "~> 7.1"},
      {:html_sanitize_ex, "~> 1.4"},
      {:gen_smtp, "~> 1.2"},
      {:castore, "~> 1.0"},
      {:mjml, "~> 6.0"},
      {:nodejs, "~> 3.0"},
      {:oban, "~> 2.20"},
      {:logger_json, "~> 7.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22"},
      {:nimble_parsec, "~> 1.4"},
      {:ex_image_info, "~> 1.0"},
      {:sweet_xml, "~> 0.7"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      # Matches mix.lock against the Elixir security advisory database. Sobelow
      # analyses this codebase; this covers the dependencies it pulls in.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # Migration safety: locks, downtime, and rewrites. Runs as its own gate
      # step (`mix excellent_migrations.check_safety`), deliberately outside
      # .credo.exs's included paths. Complements
      # CredoChecks.MigrationConstraintSafety, which covers data safety.
      {:excellent_migrations, "~> 0.1", only: [:dev, :test], runtime: false},
      # Test-quality Credo checks: tests that assert nothing, assert weakly, or
      # never reach application code. Introduced at :low priority, so they are
      # visible under --strict without gating until the backlog is triaged.
      {:jump_credo_checks, "~> 0.5", only: [:dev, :test], runtime: false},
      {:flagpack, "~> 0.6"},
      # Plug for setting conn.remote_ip from proxy headers
      {:remote_ip, "~> 1.1"},
      {:stream_data, "~> 1.1", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:phoenix_ecto, "~> 4.6"}
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
      # `mix precommit` is a task (lib/mix/tasks/precommit.ex), not an alias:
      # an alias aborts at the first failing step, and the gate is more useful
      # when one run reports everything that needs fixing.
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Every `:e2e` test module lives in this repo, and `test_helper.exs` starts
      # the endpoint and Wallaby only when E2E is set, so the tag is unrunnable
      # without this alias. Needs a local Chrome and chromedriver, which is why
      # it is not part of the default gate or of CI.
      "test.e2e": [
        &set_e2e_env/1,
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "test --color --only e2e"
      ],
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

  # `test_helper.exs` reads this to decide whether to start the HTTP endpoint and
  # Wallaby, which the browser needs to connect to.
  defp set_e2e_env(_args), do: System.put_env("E2E", "true")
end

defmodule Mix.Tasks.Dialyzer.Incremental do
  @shortdoc "Runs Dialyzer against an incremental PLT instead of a classic one"

  @moduledoc """
  Runs Dialyzer in OTP's incremental mode.

      $ mix dialyzer.incremental
      $ mix dialyzer.incremental --metrics-file /tmp/iplt-metrics.txt

  This exists alongside `mix dialyzer`, which is unchanged and remains the
  gate. Run both and compare before considering a switch; see *Warning parity*
  below.

  ## Why

  A classic PLT is cached wholesale. Dialyxir decides whether to re-check it by
  hashing `mix.lock` plus the application list
  (`Mix.Tasks.Dialyzer.dependency_hash/0`), and when that hash moves it
  re-verifies *every* module in the PLT rather than the ones that changed.
  Building one from scratch measured 589s here, and over an hour in a project
  that consumes this one as a path dependency.

  That trigger is also blind in one direction: a path dependency's source
  changes move neither `mix.lock` nor the application list, so a consuming
  project's PLT silently keeps stale typings for it. Working around that means
  invalidating dialyxir's hash by hand, which restores correctness at the cost
  of a full re-verification on every edit to the dependency.

  An incremental PLT tracks per-module hashes itself and re-analyses only what
  changed, which is exactly the missing capability. Measured against a
  one-module edit, `--metrics-file` reported one module of 4475 re-analysed.

  ## Why a separate task rather than a flag on `mix dialyzer`

  Dialyxir cannot reach incremental mode: `Mix.Tasks.Dialyzer` builds a fixed
  argument list, and its passthrough for unrecognised arguments feeds them to
  dialyzer as *warning* options, while `--incremental` is an analysis type.

  Its runner, though, splits off only its own five keys and hands everything
  else to `:dialyzer.run/1` verbatim, and `run/1` returns the same warning list
  in incremental mode as in classic mode. So calling `Dialyxir.Dialyzer.dialyze/1`
  with the extra options keeps dialyxir's Elixir-shaped formatting,
  `.dialyzer_ignore.exs` filtering and unused-filter reporting, none of which
  has to be reimplemented here.

  ## Warning parity

  Adopting this is gated on the two modes reporting the same warnings. This
  project skips 86 of them via `.dialyzer_ignore.exs`; if incremental mode
  reports even slightly differently, those filters go stale and
  `list_unused_filters` starts failing the gate for reasons unrelated to the
  code under analysis. Diff the two before switching anything.

  `--metrics-file` (incremental mode only) reports how much was skipped, which
  is how to confirm the incrementality is real rather than assumed.

  ## Options

    * `--metrics-file FILE` - write incrementality metrics to FILE
    * `--list-unused-filters` - fail when `.dialyzer_ignore.exs` has entries
      that matched nothing, mirroring the classic task's option of the same name
    * `--ignore-exit-status` - always exit 0
  """

  use Mix.Task

  alias Dialyxir.Dialyzer
  alias Dialyxir.Project

  # dialyxir is `only: [:dev], runtime: false`, so these modules are absent
  # whenever this file is compiled outside `:dev`, including every build where
  # Core is a path dependency of another project (Mix does not put the parent's
  # dev dependencies on the code path while this compiles). The task is
  # dev-only in practice, so suppress the compile-time reference rather than
  # guarding on `Code.ensure_loaded?/1`, which would silently compile the task
  # out of those builds.
  @compile {:no_warn_undefined, [Dialyxir.Dialyzer, Dialyxir.Project]}

  # Mirrors the classic task's default warning set.
  @default_warnings [:unknown]

  # The core applications dialyxir layers underneath its dependency PLT, copied
  # from `Dialyxir.Project.plts_list/3`, which builds that PLT's app set as
  # `deps ++ [:elixir] ++ [:erts, :kernel, :stdlib, :crypto]`. Classic mode gets
  # them for free by stacking three PLT files; incremental mode has a single
  # iPLT, so they have to be named in the universe explicitly. Leaving them out
  # yields thousands of `Function :erlang.get_module_info/1 does not exist`
  # warnings, reported against dependency and stdlib sources because
  # PLT-construction warnings bypass dialyxir's filtering.
  @core_apps [:elixir, :erts, :kernel, :stdlib, :crypto]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [
          metrics_file: :string,
          list_unused_filters: :boolean,
          ignore_exit_status: :boolean
        ]
      )

    Mix.Task.run("compile", [])

    {_status, exit_status, [time | result]} = opts |> dialyzer_args() |> Dialyzer.dialyze()

    Mix.shell().info(time)
    Enum.each(result, fn line -> Mix.shell().info(line) end)

    unless exit_status == 0 || opts[:ignore_exit_status] do
      Mix.shell().error("Halting VM with exit status #{exit_status}")
      System.halt(exit_status)
    end
  end

  # Incremental mode has no separate PLT-building step. Where the classic task
  # first fills a PLT with every dependency and then analyses the project files
  # against it, incremental mode maintains the iPLT itself from whatever
  # universe it is handed, so that universe has to include the dependencies.
  # Passing only the project's own beams (`{:files, dialyzer_files()}`, which is
  # exactly right for classic mode) produces an iPLT with no stdlib and no deps,
  # and the run then reports nonsense such as `String.starts_with?/2 does not
  # exist` for every external call.
  #
  # `cons_apps/0` is the universe rather than a glob of `_build/*/ebin` because
  # it is the same list the classic PLT is built from: it honours `plt_add_apps`,
  # `plt_add_deps` and, importantly, `plt_ignore_apps`, so the deliberate
  # exclusion of `:xmerl` survives. `warning_apps` then narrows *reporting* back
  # to this project, leaving dependencies analysed but silent.
  defp dialyzer_args(opts) do
    app = Mix.Project.config()[:app]

    base = [
      {:analysis_type, :incremental},
      {:init_plt, String.to_charlist(iplt_file())},
      {:apps, [app | Project.cons_apps() ++ @core_apps]},
      {:warning_apps, [app]},
      {:warnings, warnings()},
      {:format, []},
      {:list_unused_filters, opts[:list_unused_filters] || false}
    ]

    case opts[:metrics_file] do
      nil -> base
      file -> [{:metrics_file, String.to_charlist(file)} | base]
    end
  end

  # Incremental and classic PLTs are different formats and `check_init_plt_kind`
  # in dialyzer_options refuses to mix them, so this needs a file of its own.
  # The toolchain-derived stem is kept: an incremental PLT is no more portable
  # across an Erlang or Elixir version than a classic one, and reusing the stem
  # keeps both invalidating together on an upgrade.
  defp iplt_file do
    Project.plt_file()
    |> Path.rootname(".plt")
    |> Kernel.<>(".iplt")
  end

  # `Project.dialyzer_flags/0` returns the `:flags` from `mix.exs`
  # (atoms here), which the classic task passes through its own `transform/1`.
  # That function is the identity for atoms, so it is safe to omit.
  defp warnings do
    Project.dialyzer_flags() ++
      (@default_warnings -- Project.dialyzer_removed_defaults())
  end
end

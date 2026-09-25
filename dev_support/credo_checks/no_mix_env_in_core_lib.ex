defmodule CredoChecks.NoMixEnvInCoreLib do
  @moduledoc """
  Flags calls to `Mix.env/0` in Core's `lib/`.

  Core is consumed as a Mix path dependency (`{:tymeslot, path: "../tymeslot"}`
  from the SaaS repo), so `Mix.env()` does not report Core's own environment
  when it is compiled that way: it reports the *parent* project's, because
  `Mix.env/0` reads the environment of whichever project is currently
  running Mix. In a release, `Mix` is not available at all, so the call
  would raise if it were ever reached at runtime. Either way, `Mix.env()` is
  not a reliable way for Core to know its own build environment.

  Dev-only surfaces in Core gate on `Application.compile_env(:tymeslot, :dev_routes)`
  instead, which `config/dev.exs` sets to `true` and every other environment
  leaves at its default `false`. See the rationale spelt out at
  `lib/tymeslot_web/hooks/page_view_hook.ex:29`: "It is read via
  `Application.compile_env/3` rather than `Mix.env()`, which lies when Core
  is built as a path dependency."

  ## Scoping decision

  Only `lib/mix/tasks/` is exempt: a Mix task only ever runs under the `mix`
  CLI, where `Mix` is guaranteed to be loaded and `Mix.env()` reports the
  environment `mix` itself was invoked with, so the call is meaningful
  there. Everywhere else under `lib/`, the call is flagged. Test files and
  any file whose path contains `tymeslot_saas` are skipped, matching the
  registration and belt-and-braces boundary used by the other Core-only
  checks in this directory.

  ## Examples

      # Bad — Mix.env() reports the parent project's environment when Core
      # is built as a path dependency, and doesn't exist at all in a release
      defmodule TymeslotWeb.DevController do
        def index(conn, _params) do
          if Mix.env() == :dev, do: render(conn, :dev_index), else: send_resp(conn, 404, "")
        end
      end

      # Good — a compile-time flag Core owns, set by config/dev.exs
      defmodule TymeslotWeb.DevController do
        def index(conn, _params) do
          if Application.compile_env(:tymeslot, :dev_routes, false) do
            render(conn, :dev_index)
          else
            send_resp(conn, 404, "")
          end
        end
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `Mix.env()` must not be called in Core's `lib/`. Core is consumed as a
      Mix path dependency, so the call reports the parent project's
      environment rather than Core's own, and `Mix` is unavailable at all in
      a release. Gate dev-only surfaces on
      `Application.compile_env(:tymeslot, :dev_routes)` instead.
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if excluded?(filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # ---------------------------------------------------------------------------
  # Exclusions
  # ---------------------------------------------------------------------------

  defp excluded?(filename) do
    not lib_file?(filename) or mix_tasks_file?(filename) or saas_file?(filename) or
      test_file?(filename)
  end

  defp lib_file?(filename) do
    String.starts_with?(filename, "lib/") or String.contains?(filename, "/lib/")
  end

  # Mix tasks only ever run under the `mix` CLI, where Mix.env() is
  # meaningful: it reports the environment `mix` itself was invoked with.
  defp mix_tasks_file?(filename), do: String.contains?(filename, "lib/mix/tasks/")

  # Belt-and-braces: the check is only registered in Core's .credo.exs, but
  # the SaaS repo loads these same files via `requires` from the sibling
  # checkout, and Mix.env() is meaningful in the SaaS build proper.
  defp saas_file?(filename), do: String.contains?(filename, "tymeslot_saas")

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Mix]}, :env]}, meta, []} = ast,
         issues,
         issue_meta
       ) do
    issue =
      format_issue(issue_meta,
        message:
          "`Mix.env()` reports the parent project's environment when Core is built as a " <>
            "path dependency, and isn't available at all in a release. Use " <>
            "`Application.compile_env(:tymeslot, :dev_routes)` instead.",
        line_no: meta[:line],
        trigger: "Mix.env"
      )

    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}
end

defmodule CredoChecks.NoSaasReferenceInCore do
  @moduledoc """
  Flags any reference to `TymeslotSaas` from inside Core's `lib/`.

  Core is the complete, self-contained scheduling product for self-hosters:
  all domain logic, schemas, migrations, the endpoint and the full web UI
  live here. SaaS is a thin routing overlay for the managed offering, and it
  depends on Core as a Mix path dependency (`{:tymeslot, path: "../tymeslot"}`),
  never the other way round. A single reference from Core into `TymeslotSaas`
  inverts that dependency and breaks the standalone Core build outright:
  when Core is built on its own, `TymeslotSaas.*` does not exist to compile
  against.

  Core's behaviour must be identical whether the SaaS overlay is deployed on
  top of it or not. Where SaaS genuinely needs Core to behave differently
  (enforcing legal agreements, for instance), the bridge is a feature flag
  defined in Core with a safe default and overridden in SaaS config, never a
  check for SaaS's presence.

  ## What is flagged

    * Any `TymeslotSaas` alias node — this covers `alias`, `import`, `use`,
      `require`, a qualified call, a struct literal and a typespec in one
      rule, since all of them lower to the same `{:__aliases__, …}` AST node.
    * A call to `Application.get_env/2,3`, `fetch_env/2`, `fetch_env!/2`,
      `compile_env/2,3` or `compile_env!/2` whose first argument is the
      literal atom `:tymeslot_saas` — the config-key equivalent of reaching
      into the SaaS application.

  ## Scoping decision

  This check is registered in Core's `.credo.exs` only, but the SaaS repo
  loads the same check files from the sibling checkout (it `requires` them
  from `../tymeslot/dev_support/credo_checks/`), so a file under
  `tymeslot_saas/` running this check would flag its own, entirely
  legitimate, references to itself. Any file whose path contains
  `tymeslot_saas` is skipped as a cheap belt-and-braces guard, on top of the
  registration boundary. Test files are skipped too: fixtures and specs that
  exercise the Core/SaaS boundary from Core's own test suite are expected to
  mention `TymeslotSaas`.

  ## Examples

      # Bad — Core reaching into the SaaS overlay
      defmodule Tymeslot.Billing do
        alias TymeslotSaas.Billing

        def active?(user), do: Billing.active?(user)
      end

      # Bad — reading the SaaS application's own config key from Core
      defmodule Tymeslot.Billing do
        def enabled?, do: Application.get_env(:tymeslot_saas, :billing_enabled, false)
      end

      # Good — SaaS bridges the difference through a flag Core owns
      defmodule Tymeslot.Billing do
        def enforce_legal_agreements?,
          do: Application.compile_env(:tymeslot, :enforce_legal_agreements, false)
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Core never references SaaS. SaaS depends on Core as a Mix path
      dependency, never the reverse, and a reference here breaks the
      standalone Core build: `TymeslotSaas.*` does not exist outside the
      SaaS build. Bridge behavioural differences with a feature flag that
      Core owns instead.
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @saas_config_functions [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!]

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
    not lib_file?(filename) or saas_file?(filename) or test_file?(filename)
  end

  defp lib_file?(filename) do
    String.starts_with?(filename, "lib/") or String.contains?(filename, "/lib/")
  end

  # Belt-and-braces: the check is only registered in Core's .credo.exs, but
  # the SaaS repo loads these same files via `requires` from the sibling
  # checkout, so a file under its own tymeslot_saas/ tree must never trip on
  # its own, entirely legitimate, self-references.
  defp saas_file?(filename), do: String.contains?(filename, "tymeslot_saas")

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  defp traverse({:__aliases__, meta, [:TymeslotSaas | _rest]} = ast, issues, issue_meta) do
    issue =
      format_issue(issue_meta,
        message:
          "Core must never reference `TymeslotSaas`: SaaS depends on Core, not the other " <>
            "way round, and this reference breaks the standalone Core build.",
        line_no: meta[:line],
        trigger: "TymeslotSaas"
      )

    {ast, [issue | issues]}
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Application]}, func_name]}, meta, [:tymeslot_saas | _rest]} =
           ast,
         issues,
         issue_meta
       )
       when func_name in @saas_config_functions do
    issue =
      format_issue(issue_meta,
        message:
          "Core must never read the `:tymeslot_saas` application's config: that key belongs " <>
            "to the SaaS overlay, not Core. Bridge the difference with a flag Core owns.",
        line_no: meta[:line],
        trigger: "Application.#{func_name}"
      )

    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}
end

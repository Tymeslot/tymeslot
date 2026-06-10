defmodule CredoChecks.RepoCallBoundary do
  @moduledoc """
  Flags direct `Repo.*` calls outside of `*_queries.ex` and `*_schema.ex` files.

  Query and mutation logic belongs in dedicated query modules or schemas — not
  in contexts, workers, LiveViews, or other orchestration modules. This check
  enforces that boundary so Repo usage doesn't leak across the codebase.

  ## Allowed everywhere

  These calls are domain/orchestration concerns and are permitted in any file:

  - `Repo.transaction`
  - `Repo.rollback`
  - `Repo.preload`

  ## Excluded files

  - `*_queries.ex` and `*_schema.ex` — query and schema modules
  - Files under `/test/` — test files
  - Files under `/migrations/` or `/priv/repo/migrations/`
  - `repo.ex` itself
  - Files under `/deps/`

  ## Examples

      # Bad — Repo.get in a context module
      defmodule MyApp.Users do
        def get_user(id), do: Repo.get(User, id)
      end

      # Good — delegate to a queries module
      defmodule MyApp.Users.Queries do
        def get_user(id), do: Repo.get(User, id)
      end

      # OK — Repo.transaction is allowed everywhere
      defmodule MyApp.Users do
        def create_user(attrs) do
          Repo.transaction(fn -> ... end)
        end
      end
  """

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    explanations: [
      check: """
      Direct Repo calls should be confined to `*_queries.ex` and `*_schema.ex`
      files. Move query and mutation logic to a dedicated queries module.

      `Repo.transaction`, `Repo.rollback`, and `Repo.preload` are allowed
      everywhere as they are orchestration concerns, not query logic.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @flagged_functions [
    :get,
    :get!,
    :get_by,
    :get_by!,
    :one,
    :one!,
    :all,
    :exists?,
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_all,
    :update_all,
    :delete_all,
    :aggregate
  ]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if excluded?(filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      # First collect any `alias X.Y.Repo, as: DB` mappings so calls on the
      # renamed alias (`DB.get(...)`) are still recognised as Repo calls.
      repo_aliases = collect_repo_aliases(source_file)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, repo_aliases))
    end
  end

  # Builds the set of single-segment alias names (e.g. `:DB`) introduced by an
  # `alias Some.Path.Repo, as: DB` that point at a repo module.
  defp collect_repo_aliases(source_file) do
    aliases = Credo.Code.prewalk(source_file, &collect_alias(&1, &2), [])

    MapSet.new(aliases)
  end

  defp collect_alias(
         {:alias, _, [{:__aliases__, _, target_parts}, opts]} = ast,
         acc
       )
       when is_list(opts) do
    with {:ok, {:__aliases__, _, [alias_atom]}} <- Keyword.fetch(opts, :as),
         true <- repo_module?(target_parts) do
      {ast, [alias_atom | acc]}
    else
      _other -> {ast, acc}
    end
  end

  defp collect_alias(ast, acc), do: {ast, acc}

  # A module reference points at a repo when its last segment ends in "Repo"
  # (e.g. `Repo`, `Tymeslot.SaasRepo`).
  defp repo_module?(parts) when is_list(parts) do
    case List.last(parts) do
      segment when is_atom(segment) -> String.ends_with?(Atom.to_string(segment), "Repo")
      _other -> false
    end
  end

  defp repo_module?(_other), do: false

  defp excluded?(filename) do
    basename = Path.basename(filename)

    String.ends_with?(basename, "_queries.ex") or
      String.ends_with?(basename, "_schema.ex") or
      basename == "repo.ex" or
      test_file?(filename) or
      migration_file?(filename) or
      String.contains?(filename, "/deps/")
  end

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/")
  end

  defp migration_file?(filename) do
    String.contains?(filename, "/migrations/") or String.starts_with?(filename, "migrations/")
  end

  # Match Repo.function_name(...) calls in the AST.
  # The AST shape is: {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, args}
  # A call is flagged when func_name is in the flagged list AND the module
  # reference is a repo — either its last segment ends in "Repo"
  # (`Repo`, `Tymeslot.SaasRepo`) or it is a single-segment alias introduced by
  # `alias ...Repo, as: DB`.
  defp traverse(
         {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, _args} = ast,
         issues,
         issue_meta,
         repo_aliases
       ) do
    if func_name in @flagged_functions and repo_reference?(aliases, repo_aliases) do
      module_prefix = aliases |> Enum.map(&Atom.to_string/1) |> Enum.join(".")

      issue =
        format_issue(issue_meta,
          message:
            "`#{module_prefix}.#{func_name}` should only be called from " <>
              "`*_queries.ex` or `*_schema.ex` files.",
          line_no: meta[:line],
          trigger: "#{module_prefix}.#{func_name}"
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _repo_aliases), do: {ast, issues}

  defp repo_reference?(aliases, repo_aliases) do
    repo_module?(aliases) or renamed_repo_alias?(aliases, repo_aliases)
  end

  defp renamed_repo_alias?([single_segment], repo_aliases),
    do: MapSet.member?(repo_aliases, single_segment)

  defp renamed_repo_alias?(_aliases, _repo_aliases), do: false
end

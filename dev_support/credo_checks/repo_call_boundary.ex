defmodule CredoChecks.RepoCallBoundary do
  @moduledoc """
  Flags direct `Repo.*` calls outside of `*_queries.ex` files and `*_schema.ex`
  files that `use Ecto.Schema`.

  Query and mutation logic belongs in dedicated query modules or schemas — not
  in contexts, workers, LiveViews, or other orchestration modules. This check
  enforces that boundary so Repo usage doesn't leak across the codebase.

  ## Allowed everywhere

  These calls are domain/orchestration concerns and are permitted in any file:

  - `Repo.transaction`
  - `Repo.rollback`
  - `Repo.preload`

  ## Excluded files

  - `*_queries.ex` files — query modules
  - `*_schema.ex` files that `use Ecto.Schema` — schema modules; the filename
    suffix alone does not earn the exemption
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
      Direct Repo calls should be confined to `*_queries.ex` files and
      `*_schema.ex` files that `use Ecto.Schema`. Move query and mutation
      logic to a dedicated queries module.

      `Repo.transaction`, `Repo.rollback`, and `Repo.preload` are allowed
      everywhere as they are orchestration concerns, not query logic.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  # Everything except these three orchestration concerns is a query/mutation
  # call and must live in a `*_queries.ex` or `*_schema.ex` file. This is an
  # allowlist, not a denylist, so a newly-called `Repo.*` function is flagged
  # by default rather than silently passing until someone remembers to list it.
  @allowed_functions [:transaction, :rollback, :preload]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if excluded?(filename, source_file) do
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

  # `Ecto.Repo` itself is the behaviour, never an app repo the codebase calls
  # queries on directly; the only place it appears is `Ecto.Repo.t()` in a
  # `@spec`, which is a type reference, not a call to flag.
  defp repo_module?([:Ecto, :Repo]), do: false

  # A module reference points at a repo when its last segment ends in "Repo"
  # (e.g. `Repo`, `Tymeslot.SaasRepo`).
  defp repo_module?(parts) when is_list(parts) do
    case List.last(parts) do
      segment when is_atom(segment) -> String.ends_with?(Atom.to_string(segment), "Repo")
      _other -> false
    end
  end

  defp repo_module?(_other), do: false

  defp excluded?(filename, source_file) do
    basename = Path.basename(filename)

    String.ends_with?(basename, "_queries.ex") or
      schema_file?(basename, source_file) or
      basename == "repo.ex" or
      test_file?(filename) or
      migration_file?(filename) or
      String.contains?(filename, "/deps/")
  end

  # The `_schema.ex` suffix earns the exemption only when the file really is an
  # Ecto schema. Keying on the name alone let any module named that way opt out
  # of the boundary by filename, with nothing to warn a reader that it had.
  #
  # The source is stripped of strings, sigils and heredocs first so a `use
  # Ecto.Schema` mentioned inside a `@moduledoc` (or any other string/heredoc)
  # doesn't grant the exemption to a module that never actually uses it.
  defp schema_file?(basename, source_file) do
    String.ends_with?(basename, "_schema.ex") and
      Credo.Code.clean_charlists_strings_and_sigils(source_file) =~
        ~r/^\s*use\s+Ecto\.Schema\b/m
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
    if func_name not in @allowed_functions and repo_reference?(aliases, repo_aliases) do
      module_prefix = aliases |> Enum.map(&Atom.to_string/1) |> Enum.join(".")

      issue =
        format_issue(issue_meta,
          message:
            "`#{module_prefix}.#{func_name}` should only be called from " <>
              "`*_queries.ex` files or `*_schema.ex` files that `use Ecto.Schema`.",
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

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
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

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
  # We check that the last alias segment is :Repo and func_name is in the flagged list.
  defp traverse(
         {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    if List.last(aliases) == :Repo and func_name in @flagged_functions do
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

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}
end

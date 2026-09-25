defmodule CredoChecks.PreloadOrderThroughAssociation do
  @moduledoc """
  Flags `preload_order:` combined with `:through` on `has_many`/`has_one`.

  Ecto accepts the combination without a warning or an error, and then drops
  `:preload_order` on the floor. `has_many`'s `check_options!/3` allows the key
  (it is in `@valid_has_many_options`), but `Ecto.Association.HasThrough.struct/3`
  (`deps/ecto/lib/ecto/association.ex`) builds a struct with no `preload_order`
  field at all and never reads `opts[:preload_order]`, so the value that was
  accepted is never looked at again. The ordering the author asked for silently
  does not happen.

  Ecto's own docs make the same point about the option next to it: `:where`
  "does not apply to `:through` associations" (`deps/ecto/lib/ecto/schema.ex:799`).
  `:preload_order` is not spelt out beside it, but the mechanism is identical:
  both options are accepted by `check_options!/3` and then simply absent from
  the struct `HasThrough.struct/3` builds. This is also a documented project
  gotcha, listed in this repository's `CLAUDE.md` under "Known Gotchas".

  `has_one` is flagged for the same combination for the same reason: whether a
  given Ecto version instead rejects `:preload_order` on `has_one` outright (it
  is missing from `@valid_has_one_options` as of the Ecto version this project
  pins), catching the combination here is still strictly better than waiting
  for a compile-time crash, and the fix is the same either way.

  There is no legitimate reason to write this combination, so this check has no
  allowlist and no opt-out.

  ## What to do instead

  Order the underlying association the `:through` path traverses (put
  `preload_order:` on the association `:through` steps into, not on the
  `:through` association itself), or sort the preloaded records after loading.

  ## Examples

      # Bad — preload_order is silently dropped on a :through association
      defmodule MyApp.Schedule do
        use Ecto.Schema

        schema "schedules" do
          has_many :slots, through: [:schedule_days, :slots], preload_order: [asc: :starts_at]
        end
      end

      # Good — the ordering lives on the association actually being loaded
      defmodule MyApp.ScheduleDay do
        use Ecto.Schema

        schema "schedule_days" do
          has_many :slots, MyApp.Slot, preload_order: [asc: :starts_at]
        end
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      preload_order: has no effect on a :through association.

      has_many/has_one accept the combination without warning, but
      Ecto.Association.HasThrough.struct/3 builds a struct with no
      preload_order field and never reads it, so the ordering never applies.

      Move preload_order: onto the association the :through path traverses,
      or sort the preloaded records after loading.
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if lib_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # File scope
  # ---------------------------------------------------------------------------

  defp lib_file?(filename) do
    case Path.split(filename) do
      ["lib" | _rest] -> true
      _other -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  defp traverse({call, meta, args} = ast, issues, issue_meta)
       when call in [:has_many, :has_one] and is_list(args) do
    case last_keyword_opts(args) do
      opts when is_list(opts) ->
        if Keyword.has_key?(opts, :through) and Keyword.has_key?(opts, :preload_order) do
          {ast, [build_issue(issue_meta, meta[:line], call) | issues]}
        else
          {ast, issues}
        end

      nil ->
        {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # The options keyword list is always the last positional argument, whether
  # it arrived as `has_many :name, Schema, opts` or the through form
  # `has_many :name, through: [...], preload_order: [...]` (where the through
  # form's keyword list is itself the second argument).
  defp last_keyword_opts(args) do
    case List.last(args) do
      list when is_list(list) -> if Keyword.keyword?(list), do: list
      _other -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Issues
  # ---------------------------------------------------------------------------

  defp build_issue(issue_meta, line_no, call) do
    format_issue(issue_meta,
      message:
        "`preload_order:` has no effect alongside `:through` on `#{call}`: Ecto accepts it " <>
          "and never applies it. Put `preload_order:` on the association the `:through` path " <>
          "traverses, or sort the preloaded records after loading.",
      line_no: line_no,
      trigger: "#{call}"
    )
  end
end

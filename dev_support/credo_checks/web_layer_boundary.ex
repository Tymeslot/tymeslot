defmodule CredoChecks.WebLayerBoundary do
  @moduledoc """
  Flags presentation-layer modules that reach past a context into its
  internals: query modules, background job enqueuing, and runtime adapter
  modules.

  LiveViews, LiveComponents, controllers and their helper modules orchestrate;
  they do not compute. The context module is the single entry point for its
  domain, so a web module that calls a `*Queries` module, builds and inserts
  an Oban job, or drives a calendar runtime adapter has taken on a decision
  that belongs to the context, and a second caller will copy it rather than
  reuse it.

  ## Flagged

  In files under `lib/tymeslot_web/` and `lib/tymeslot_saas_web/`:

  - **Query modules.** An `alias` (including an entry of a multi-alias
    `{...}` and an `alias ..., as: X`) or `import` of any module whose last
    segment ends in `Queries`, and any remote call or capture that names one
    without going through such an alias (`Tymeslot.Meetings.MeetingQueries.get_meeting(id)`,
    `Meetings.MeetingQueries.get_meeting(id)`).
  - **Enqueuing jobs.** Calls to `Oban.insert`, `Oban.insert!` and
    `Oban.insert_all`, at any arity, and calls to `new` on a worker module:
    one whose last segment ends in `Worker` or `Job`, or that sits under a
    `Workers` namespace (`Tymeslot.Workers.VideoTranscoder`). Worker names are
    resolved through the file's aliases, so `alias Tymeslot.Workers.X` followed
    by `X.new(args)` is caught.
  - **Forbidden modules.** An `alias`/`import` of, or a call naming, a module
    in the `:forbidden_modules` param or any module below one. The default is
    the calendar runtime layer (`lib/tymeslot/integrations/calendar/runtime/`):
    `Tymeslot.Integrations.Calendar.Operations`, `EventsRead`,
    `RequestCoalescer`, and everything under
    `Tymeslot.Integrations.Calendar.Runtime`. Web code reaches calendar writes
    and reads through `Tymeslot.Integrations.Calendar` and its public
    submodules such as `Calendar.Events`.

  ## Scoping decision

  - **Aliases, not every call through them.** A flagged module that is
    aliased is reported once, at the `alias` line; calls through that alias
    are not reported again, since removing the alias is the fix and one issue
    per call would bury it. Calls that name the module without such an alias
    are reported at the call.
  - **Suffix rules for query modules and workers, a list for adapters.** Query
    and worker modules follow naming conventions the codebase already keeps,
    so a new one is caught by default. Runtime adapters have no such
    convention (`Calendar.Operations` implements a behaviour and is named for
    it), so they are an explicit list that replaces the default when given.
    Only the calendar integration has a runtime layer today; a new one belongs
    in the default list.
  - **Arity is ignored for `Oban.insert*` and `Worker.new`.** Every arity
    enqueues or builds a job, and a piped call (`job |> Oban.insert()`) has one
    fewer argument in the AST than it does at runtime.
  - **Both `Worker.new` and `Oban.insert` are flagged**, so the usual
    `args |> Worker.new() |> Oban.insert()` pipeline reports two issues. Either
    call alone is already the web layer deciding how a job is built or
    enqueued.
  - **Not flagged:** schema modules (the web layer legitimately uses them for
    structs, pattern matching and types), context and sibling feature modules,
    other `Oban` functions (read-only queue introspection), `Repo` calls
    (already reported by `CredoChecks.RepoCallBoundary`, and not reported
    twice here), modules in the `TymeslotWeb`/`TymeslotSaasWeb` namespaces
    (a web helper that happens to end in `Queries` or `Job` is not a context
    internal), and anything in comments, `@moduledoc` or `@doc`, since the
    check walks the AST.
  - Test files are excluded, as is any file outside the two web directories.

  An `:allowed` param (list of filename substrings) exempts a reviewed
  exception:

      {CredoChecks.WebLayerBoundary, [allowed: ["lib/tymeslot_web/some/exception.ex"]]}

  ## Examples

      # Bad: a LiveComponent reading through a query module
      alias Tymeslot.Meetings.MeetingQueries
      MeetingQueries.count_awaiting_approval_for_organizer(user.id)

      # Good: the context owns the read
      Meetings.count_awaiting_approval(user)

      # Bad: a LiveComponent enqueuing a job
      %{"integration_id" => id} |> SyncIcsCalendarWorker.new() |> Oban.insert()

      # Good: the context owns the enqueue
      Calendar.request_sync(integration)

  ## Not attempted

  This check covers one of the four web-layer boundary rules in
  `CONTRIBUTING.md`. The other three, ownership enforcement in contexts,
  async work staying in the domain, and UI pre-validation reusing the domain
  rule, are conventions caught by review, and the documentation says so.

  Ownership is the security-relevant one, so it was prototyped: flag a call
  from a web module to a context function that names a resource id but no
  acting user or scope. Measured against the two cross-tenant leaks this
  codebase has fixed, it caught one (`payment_for_meeting(meeting.id)`) and
  missed the other, whose offending call went through a query module and is
  already this check's rule. Across the web layer it raised thirteen hits,
  none of them a real gap: an id read off an already-scoped record
  (`poll.confirmed_meeting_id`, a profile id fetched from the current user)
  is indistinguishable, in the AST, from one posted by the browser, and that
  distinction is the whole rule. Matching instead on an `{:error, :not_found}`
  return is worse: both fixed bugs returned exactly that shape while broken,
  because the row was found and simply belonged to someone else.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      allowed: [],
      forbidden_modules: [
        Tymeslot.Integrations.Calendar.Operations,
        Tymeslot.Integrations.Calendar.EventsRead,
        Tymeslot.Integrations.Calendar.RequestCoalescer,
        Tymeslot.Integrations.Calendar.Runtime
      ]
    ],
    explanations: [
      check: """
      Web modules (LiveViews, LiveComponents, controllers and their helpers)
      must go through a context's public API. They must not alias or call
      `*Queries` modules, build or insert Oban jobs, or call runtime adapter
      modules such as `Tymeslot.Integrations.Calendar.Operations`.
      """,
      params: [
        allowed: "List of filename substrings exempt from the check.",
        forbidden_modules:
          "Modules web code must not reference; each also forbids every module below it."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @web_dirs ["lib/tymeslot_web/", "lib/tymeslot_saas_web/"]
  @web_namespaces [:TymeslotWeb, :TymeslotSaasWeb]
  @oban_insert_functions [:insert, :insert!, :insert_all]
  @reference_directives [:alias, :import]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if in_scope?(filename, Params.get(params, :allowed, __MODULE__)) do
      forbidden =
        params
        |> Params.get(:forbidden_modules, __MODULE__)
        |> Enum.map(&module_segments/1)

      ctx = %{
        issue_meta: IssueMeta.for(source_file, params),
        aliases: collect_aliases(source_file),
        forbidden: forbidden
      }

      Credo.Code.prewalk(source_file, &traverse(&1, &2, ctx))
    else
      []
    end
  end

  defp in_scope?(filename, allowed) do
    Enum.any?(@web_dirs, &String.contains?(filename, &1)) and
      not test_file?(filename) and
      not Enum.any?(allowed, &String.contains?(filename, &1))
  end

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # Compared as strings: the segment atoms of a module in the param list need
  # not exist, and creating them from config is what `String.to_atom` warns of.
  defp module_segments(module), do: Module.split(module)

  ## Alias resolution

  # Maps each short name the file introduces to the full segments it stands
  # for: `alias A.B.C` gives `:C => [:A, :B, :C]`, and `as: D` gives `:D`.
  defp collect_aliases(source_file) do
    source_file
    |> Credo.Code.prewalk(&collect_alias/2, [])
    |> Map.new()
  end

  defp collect_alias({:alias, _, [target | opts]} = ast, acc) do
    entries =
      case {expand_targets(target), opts} do
        {[{_ast, segments}], [[as: {:__aliases__, _, [short]}]]} ->
          [{short, segments}]

        {targets, _opts} ->
          Enum.map(targets, fn {_ast, segments} -> {List.last(segments), segments} end)
      end

    {ast, entries ++ acc}
  end

  defp collect_alias(ast, acc), do: {ast, acc}

  # Returns `{alias_ast, segments}` for each module a directive names: one for
  # `alias A.B`, one per entry for `alias A.{B, C.D}`. Segments that are not
  # literal atoms (`__MODULE__.X`) make the target unresolvable and drop it.
  defp expand_targets({:__aliases__, _, segments} = ast) do
    if Enum.all?(segments, &is_atom/1), do: [{ast, segments}], else: []
  end

  defp expand_targets({{:., _, [{:__aliases__, _, base}, :{}]}, _, entries}) do
    if Enum.all?(base, &is_atom/1) do
      for {:__aliases__, _, segments} = ast <- entries,
          Enum.all?(segments, &is_atom/1),
          do: {ast, base ++ segments}
    else
      []
    end
  end

  defp expand_targets(_other), do: []

  defp resolve([head | rest], aliases) do
    case Map.fetch(aliases, head) do
      {:ok, full} -> full ++ rest
      :error -> [head | rest]
    end
  end

  ## Traversal

  defp traverse({directive, _, [target | _opts]} = ast, issues, ctx)
       when directive in @reference_directives do
    new_issues =
      for {{:__aliases__, meta, written}, segments} <- expand_targets(target),
          kind = internal_kind(segments, ctx.forbidden),
          kind != nil,
          do: boundary_issue(ctx.issue_meta, kind, segments, join(written), meta[:line])

    {ast, new_issues ++ issues}
  end

  # `fun != :{}` skips the base of a multi-alias (`alias A.{B, C}`), which has
  # the same shape as a remote call; the `alias` clause above handles it.
  defp traverse({{:., _, [{:__aliases__, _, written}, fun]}, meta, args} = ast, issues, ctx)
       when is_atom(fun) and fun != :{} and is_list(args) do
    if Enum.all?(written, &is_atom/1) do
      {ast, call_issues(written, fun, meta[:line], ctx) ++ issues}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _ctx), do: {ast, issues}

  defp call_issues(written, fun, line, ctx) do
    segments = resolve(written, ctx.aliases)

    cond do
      segments == [:Oban] and fun in @oban_insert_functions ->
        [job_issue(ctx.issue_meta, "Oban.#{fun}", written, fun, line)]

      fun == :new and worker?(segments) ->
        [job_issue(ctx.issue_meta, "#{join(segments)}.new", written, fun, line)]

      via_reported_alias?(written, ctx) ->
        []

      true ->
        case internal_kind(segments, ctx.forbidden) do
          nil ->
            []

          kind ->
            [boundary_issue(ctx.issue_meta, kind, segments, "#{join(written)}.#{fun}", line)]
        end
    end
  end

  # A call through an alias that is itself a flagged module was already
  # reported at the `alias` line.
  defp via_reported_alias?([head | _rest], ctx) do
    case Map.fetch(ctx.aliases, head) do
      {:ok, full} -> internal_kind(full, ctx.forbidden) != nil
      :error -> false
    end
  end

  ## Classification

  defp internal_kind([namespace | _rest], _forbidden) when namespace in @web_namespaces, do: nil

  defp internal_kind(segments, forbidden) do
    names = Enum.map(segments, &Atom.to_string/1)

    cond do
      Enum.any?(forbidden, &List.starts_with?(names, &1)) -> :forbidden
      segments |> List.last() |> ends_with?("Queries") -> :queries
      true -> nil
    end
  end

  defp worker?([namespace | _rest]) when namespace in @web_namespaces, do: false

  defp worker?(segments) do
    last = List.last(segments)

    ends_with?(last, "Worker") or ends_with?(last, "Job") or
      :Workers in Enum.drop(segments, -1)
  end

  defp ends_with?(segment, suffix), do: segment |> Atom.to_string() |> String.ends_with?(suffix)

  defp join(segments), do: Enum.map_join(segments, ".", &Atom.to_string/1)

  ## Issues

  defp boundary_issue(issue_meta, kind, segments, trigger, line) do
    format_issue(issue_meta,
      message:
        "`#{join(segments)}` #{describe(kind)}; go through its context's public API instead.",
      line_no: line,
      trigger: trigger
    )
  end

  defp job_issue(issue_meta, name, written, fun, line) do
    format_issue(issue_meta,
      message:
        "`#{name}` builds or enqueues a background job in the web layer; " <>
          "expose the enqueue through its context's public API instead.",
      line_no: line,
      trigger: "#{join(written)}.#{fun}"
    )
  end

  defp describe(:queries), do: "is a query module internal to its context"
  defp describe(:forbidden), do: "is a runtime adapter module, not public API"
end

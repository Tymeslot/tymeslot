defmodule CredoChecks.AttendeeNotificationsBoundary do
  @moduledoc """
  Flags direct calls to calendar-invitation schedulers from outside
  `Tymeslot.Meetings.AttendeeNotifications`.

  `Tymeslot.Meetings.AttendeeNotifications` is the single entry point for every
  calendar-event attendee message. Bypassing it by calling the underlying
  orchestrator or `CalendarScheduler` directly re-introduces the duplication
  and divergence problems the centralisation was meant to solve.

  ## Flagged functions

  - `Tymeslot.Notifications.Orchestrator.schedule_calendar_invitations/3`
  - `Tymeslot.Notifications.Orchestrator.schedule_event_update_notification/2`
  - `Tymeslot.Emails.EmailScheduler.CalendarScheduler.schedule_calendar_invitation/1`
  - `Tymeslot.Emails.EmailScheduler.CalendarScheduler.schedule_event_update_notification/1`

  ## Allowed call sites

  - `lib/tymeslot/meetings/attendee_notifications.ex` and its submodules
  - The `Orchestrator` and `CalendarScheduler` modules themselves (internal
    composition between the two layers)
  - Worker handler modules under
    `lib/tymeslot/workers/email_worker_handlers/` — these are downstream
    of the scheduler, not callers of it
  - Tests (`*_test.exs`)
  - Migrations (`priv/repo/migrations/`)
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Calendar-invitation scheduling must go through
      `Tymeslot.Meetings.AttendeeNotifications`. Calling the orchestrator or
      `CalendarScheduler` directly bypasses the centralised change detection,
      rate limiting, and last-notified-state tracking.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  # Flagged calls: {module suffix (last N aliases), func, arity}
  @flagged [
    {[:Notifications, :Orchestrator], :schedule_calendar_invitations, 3},
    {[:Notifications, :Orchestrator], :schedule_event_update_notification, 2},
    {[:Emails, :EmailScheduler, :CalendarScheduler], :schedule_calendar_invitation, 1},
    {[:Emails, :EmailScheduler, :CalendarScheduler], :schedule_event_update_notification, 1}
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
    attendee_notifications_file?(filename) or
      scheduler_internal_file?(filename) or
      worker_handler_file?(filename) or
      test_file?(filename) or
      migration_file?(filename) or
      String.contains?(filename, "/deps/")
  end

  defp attendee_notifications_file?(filename) do
    String.contains?(filename, "/meetings/attendee_notifications/") or
      String.ends_with?(filename, "/meetings/attendee_notifications.ex")
  end

  defp scheduler_internal_file?(filename) do
    String.ends_with?(filename, "/notifications/orchestrator.ex") or
      String.ends_with?(filename, "/email_scheduler/calendar_scheduler.ex")
  end

  defp worker_handler_file?(filename) do
    String.contains?(filename, "/workers/email_worker_handlers/")
  end

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  defp migration_file?(filename) do
    String.contains?(filename, "/migrations/") or String.starts_with?(filename, "migrations/")
  end

  # Match Module.function(args) calls in the AST.
  # AST shape: {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, args}
  defp traverse(
         {{:., _, [{:__aliases__, _, aliases}, func_name]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when is_list(aliases) and is_list(args) do
    arity = length(args)

    case find_flagged(aliases, func_name, arity) do
      nil ->
        {ast, issues}

      {alias_suffix, func, flagged_arity} ->
        module_prefix = alias_suffix |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
        trigger = "#{module_prefix}.#{func}"

        issue =
          format_issue(issue_meta,
            message:
              "`#{module_prefix}.#{func}/#{flagged_arity}` should only be called through " <>
                "`Tymeslot.Meetings.AttendeeNotifications`.",
            line_no: meta[:line],
            trigger: trigger
          )

        {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp find_flagged(aliases, func_name, arity) do
    Enum.find(@flagged, fn {suffix, func, flagged_arity} ->
      func == func_name and arity == flagged_arity and suffix_match?(aliases, suffix)
    end)
  end

  # True when the `suffix` list appears at the tail of `aliases`. This makes
  # the check resilient to whether the call site uses a fully qualified name
  # (`Tymeslot.Notifications.Orchestrator.foo/3`) or an aliased short form
  # (`Orchestrator.foo/3`).
  defp suffix_match?(aliases, suffix) do
    aliases_len = length(aliases)
    suffix_len = length(suffix)

    cond do
      aliases_len < suffix_len -> false
      aliases_len == suffix_len -> aliases == suffix
      true -> Enum.drop(aliases, aliases_len - suffix_len) == suffix
    end
  end
end

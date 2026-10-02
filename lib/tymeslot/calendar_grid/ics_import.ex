defmodule Tymeslot.CalendarGrid.IcsImport do
  @moduledoc """
  Imports the events of an uploaded `.ics` file into one of the user's
  writable calendars.

  Importing is a copy, not a subscription: each VEVENT is written to the
  chosen calendar as a new event of its own, under a fresh UID, so it can be
  edited there like any other and a second import of the same file never
  overwrites the first. A feed that should stay in step with its publisher is
  the ICS subscription provider's job, not this one.

  The work is split up so the dashboard can show what a file holds before
  anything is written:

    * `plan/1` parses the file and turns it into the events to write,
    * `target/3` checks the calendar chosen is the user's and writable, and
    * `run/3` writes a plan to it.

  An imported event keeps its title, description, location, timing,
  recurrence and free/busy flag. Its organiser and attendees are dropped: an
  import must never send invitations on someone else's behalf, and the
  attendees of a meeting the user was invited to are not theirs to invite.

  A series' cancelled occurrences, and those moved by an override, are carried
  across as exclusions on the series, and each moved occurrence is written as
  an event of its own at its new time. Outlook takes no exclusions when a
  series is created, so `run/3` reports how many series it wrote without them.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalParser

  # A full export of a busy calendar runs to a few megabytes; the parser holds
  # the whole document in memory, so the cap is kept a little above that.
  @max_bytes 5_000_000
  # Every event is a provider write, made one after another so as not to trip
  # a provider's own rate limit; a thousand takes a few minutes.
  @max_events 1_000
  # Writing on would only fail the same way for every remaining event.
  @fatal_errors [:unauthorized, :not_found, :read_only]
  # The failed titles reported back are a sample for the user to recognise,
  # not a log.
  @failed_sample_size 5

  @type event_data :: %{
          required(:summary) => String.t(),
          required(:start_time) => DateTime.t() | Date.t(),
          required(:end_time) => DateTime.t() | Date.t(),
          required(:all_day) => boolean(),
          optional(atom()) => term()
        }

  @type plan :: %{
          events: [event_data()],
          series: non_neg_integer(),
          cancelled: non_neg_integer()
        }

  @type target :: %{
          user_id: pos_integer(),
          integration: CalendarIntegrationSchema.t(),
          calendar_id: String.t() | nil
        }

  @type plan_error :: :too_large | :invalid_file | :no_events | :too_many_events

  @type summary :: %{
          total: non_neg_integer(),
          created: non_neg_integer(),
          failed: non_neg_integer(),
          failed_titles: [String.t()],
          exclusions_dropped: non_neg_integer(),
          halted: atom() | nil
        }

  @doc "The largest file `plan/1` accepts, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most events one file may hold."
  @spec max_events() :: pos_integer()
  def max_events, do: @max_events

  @doc """
  Parses an `.ics` document into the events an import would write.

  Cancelled events are left out and counted under `:cancelled`; `:series`
  counts the recurring ones among `:events`.
  """
  @spec plan(binary()) :: {:ok, plan()} | {:error, plan_error()}
  def plan(content) when is_binary(content) and byte_size(content) > @max_bytes,
    do: {:error, :too_large}

  def plan(content) when is_binary(content) do
    with {:ok, raw_events} <- parse(content) do
      {cancelled, live} = Enum.split_with(raw_events, &cancelled?/1)
      events = build_events(live, cancelled)

      cond do
        events == [] ->
          {:error, :no_events}

        length(events) > @max_events ->
          {:error, :too_many_events}

        true ->
          {:ok, %{events: events, series: count_series(events), cancelled: length(cancelled)}}
      end
    end
  end

  @doc """
  Resolves where an import is written: `calendar_id` on the user's active,
  writable integration `integration_id`.

  `calendar_id` may be `nil` for an integration whose calendars have not been
  discovered, which is written to through the provider's own default; any
  other value must name one of its writable calendars. Anything else, an
  integration of another user's included, is `{:error, :not_found}`.
  """
  @spec target(pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, target()} | {:error, :not_found}
  def target(user_id, integration_id, calendar_id) do
    with {:ok, integration} <- owned_active_integration(user_id, integration_id),
         true <- Calendar.writable_integrations([integration]) != [],
         true <- writable_calendar?(integration, calendar_id) do
      {:ok, %{user_id: user_id, integration: integration, calendar_id: calendar_id}}
    else
      _not_writable -> {:error, :not_found}
    end
  end

  @doc """
  Writes the events of `plan` to `target`, one after another.

  A failed write is counted and the import carries on, unless the provider
  refused in a way every later write would repeat (`#{inspect(@fatal_errors)}`),
  in which case it stops and names the reason under `:halted`.

  Options:

    * `:on_progress` - called with the number of events handled so far after
      each one, so a caller can show progress.
  """
  @spec run(target(), plan(), keyword()) :: summary()
  def run(target, %{events: events}, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _done -> :ok end)

    initial = %{
      total: length(events),
      created: 0,
      failed: 0,
      failed_titles: [],
      exclusions_dropped: 0,
      halted: nil
    }

    summary =
      events
      |> Enum.with_index(1)
      |> Enum.reduce_while(initial, fn {event, done}, acc ->
        acc = write_event(event, target, acc)
        on_progress.(done)
        if acc.halted, do: {:halt, acc}, else: {:cont, acc}
      end)

    Map.update!(summary, :failed_titles, &Enum.reverse/1)
  end

  # --- Parsing ---

  # A byte-order mark ahead of `BEGIN:VCALENDAR` is common in files saved on
  # Windows and is not part of the document.
  defp parse(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: parse(rest)

  defp parse(content) do
    if String.valid?(content) do
      case ICalParser.parse(content) do
        {:ok, raw_events} -> {:ok, raw_events}
        {:error, _reason} -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  defp cancelled?(raw), do: String.upcase(raw[:status] || "") == "CANCELLED"

  defp override?(raw), do: is_binary(raw[:recurrence_id]) and raw[:recurrence_id] != ""

  defp series?(raw), do: is_binary(raw[:recurrence_rule]) and raw[:recurrence_rule] != ""

  # An override replaces one occurrence of the series sharing its UID. When
  # that series is in the file, the occurrence it replaces is excluded from
  # the series and the override is written as an event of its own; a
  # cancelled override only excludes. An override whose series is not in the
  # file has nothing to exclude from and stands alone.
  defp build_events(live, cancelled) do
    series_by_uid =
      for raw <- live, series?(raw), not override?(raw), into: %{}, do: {raw.uid, raw}

    replaced =
      for raw <- live ++ cancelled,
          override?(raw),
          series = series_by_uid[raw.uid],
          slot = occurrence_slot(raw.recurrence_id, series),
          reduce: %{} do
        acc -> Map.update(acc, raw.uid, [slot], &[slot | &1])
      end

    Enum.map(live, fn raw ->
      if override?(raw),
        do: event_data(raw, nil, []),
        else: event_data(raw, raw[:recurrence_rule], series_exclusions(raw, replaced))
    end)
  end

  defp series_exclusions(raw, replaced) do
    if series?(raw),
      do: Enum.uniq((raw[:exdates] || []) ++ Map.get(replaced, raw.uid, [])),
      else: []
  end

  defp event_data(raw, rule, exclusions) do
    all_day = is_struct(raw.start_time, Date)

    Map.reject(
      %{
        summary: raw[:summary] || "",
        description: raw[:description],
        location: raw[:location],
        start_time: raw.start_time,
        end_time: raw.end_time,
        all_day: all_day,
        timezone: raw[:timezone],
        recurrence_rule: rule,
        recurrence_exceptions: exclusions,
        transparency: transparency(raw[:transparency])
      },
      fn {_key, value} -> value in [nil, []] end
    )
  end

  defp transparency("transparent"), do: :transparent
  defp transparency("opaque"), do: :opaque
  defp transparency(_other), do: nil

  # A `RECURRENCE-ID` is written in the value type of the series' DTSTART: a
  # date for an all-day series, otherwise a UTC instant (`Z`) or a wall clock
  # in the series' own zone.
  @recurrence_id ~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/

  defp occurrence_slot(value, series) do
    case Regex.run(@recurrence_id, String.trim(value)) do
      [_all, y, m, d] -> date(y, m, d)
      [_all, y, m, d, hh, mm, ss, "Z"] -> instant([y, m, d, hh, mm, ss], "Etc/UTC")
      [_all, y, m, d, hh, mm, ss, ""] -> instant([y, m, d, hh, mm, ss], series[:timezone])
      _unreadable -> nil
    end
  end

  defp date(y, m, d) do
    case Date.new(to_int(y), to_int(m), to_int(d)) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp instant([y, m, d, hh, mm, ss], zone) do
    with {:ok, naive} <-
           NaiveDateTime.new(to_int(y), to_int(m), to_int(d), to_int(hh), to_int(mm), to_int(ss)),
         {:ok, local} <- DateTime.from_naive(naive, zone || "Etc/UTC") do
      DateTime.shift_zone!(local, "Etc/UTC")
    else
      _unresolvable -> nil
    end
  end

  defp to_int(digits), do: String.to_integer(digits)

  defp count_series(events), do: Enum.count(events, &Map.has_key?(&1, :recurrence_rule))

  # --- Writing ---

  defp owned_active_integration(user_id, integration_id) do
    case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, %{is_active: true} = integration} -> {:ok, integration}
      _missing_or_inactive -> {:error, :not_found}
    end
  end

  defp writable_calendar?(%{calendar_list: list}, nil), do: list in [nil, []]

  defp writable_calendar?(%{calendar_list: list}, calendar_id),
    do: Enum.any?(Calendar.writable_calendars(list), &(&1.id == calendar_id))

  defp write_event(event, %{integration: integration} = target, acc) do
    data =
      Map.merge(event, %{
        uid: ICalBuilder.generate_uid(),
        calendar_integration_id: integration.id,
        calendar_id: target.calendar_id
      })

    case CalendarEvents.create_event(data, {integration.id, target.user_id}) do
      {:ok, _created} ->
        %{
          acc
          | created: acc.created + 1,
            exclusions_dropped: acc.exclusions_dropped + dropped_exclusions(event, integration)
        }

      {:error, reason} ->
        %{
          acc
          | failed: acc.failed + 1,
            failed_titles: sample_title(acc.failed_titles, event.summary),
            halted: if(reason in @fatal_errors, do: reason)
        }
    end
  end

  defp dropped_exclusions(%{recurrence_exceptions: [_one | _more]}, %{provider: "outlook"}), do: 1
  defp dropped_exclusions(_event, _integration), do: 0

  defp sample_title(titles, title) when length(titles) < @failed_sample_size,
    do: [title | titles]

  defp sample_title(titles, _title), do: titles
end

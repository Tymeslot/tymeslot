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
  recurrence and free/busy flag. A floating time (one with no zone) is read
  as a wall-clock time in the importing user's zone, and a zone the time-zone
  database does not know is not passed on to the provider. Its organiser and attendees are dropped: an
  import must never send invitations on someone else's behalf, and the
  attendees of a meeting the user was invited to are not theirs to invite.

  A series' cancelled occurrences, and those moved by an override, are carried
  across as exclusions on the series, and each moved occurrence is written as
  an event of its own at its new time; a change to an occurrence and every
  later one splits the series there (see `IcsImport.Series`). Outlook takes no exclusions when a
  series is created, so `run/3` reports how many series it wrote without them.
  """

  alias Tymeslot.CalendarGrid.IcsImport.Series
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Timezones

  require Logger

  # A full export of a busy calendar runs to a few megabytes; the parser holds
  # the whole document in memory, so the cap is kept a little above that.
  @max_bytes 5_000_000
  # Every event is a provider write, made one after another so as not to trip
  # a provider's own rate limit; a thousand takes a few minutes.
  @max_events 1_000
  # A timed event is never written without a zone: Google requires one on a
  # series, and a UTC instant is exactly what a zoneless time was read as.
  @utc "Etc/UTC"
  # Writing on would only fail the same way for every remaining event; an
  # open circuit breaker refuses every write until it recovers.
  @fatal_errors [:unauthorized, :not_found, :read_only, :circuit_open]
  # This many failures in a row means the provider itself is failing, not
  # the events: a stalled server would otherwise cost one timeout per event.
  @max_failures_in_a_row 5
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

  @type import_error :: :already_running

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
  Parses an `.ics` document into the events an import would write, reading
  any floating time as a wall-clock time in `timezone`.

  Cancelled events are left out and counted under `:cancelled`; `:series`
  counts the recurring ones among `:events`.
  """
  @spec plan(binary(), String.t()) :: {:ok, plan()} | {:error, plan_error()}
  def plan(content, timezone \\ @utc)

  def plan(content, _timezone) when is_binary(content) and byte_size(content) > @max_bytes,
    do: {:error, :too_large}

  def plan(content, timezone) when is_binary(content) do
    # Counted before parsing, which costs far more than the count: a file of
    # tens of thousands of events is refused without being read.
    if vevent_count(content) > @max_events do
      {:error, :too_many_events}
    else
      build_plan(content, timezone)
    end
  end

  defp build_plan(content, timezone) do
    with {:ok, raw_events} <- parse(content) do
      zone = if Timezones.valid?(timezone), do: timezone, else: @utc
      raw_events = Enum.map(raw_events, &anchor_floating(&1, zone))
      {cancelled, live} = Enum.split_with(raw_events, &cancelled?/1)

      case build_events(live, cancelled) do
        [] ->
          {:error, :no_events}

        events ->
          {:ok, %{events: events, series: count_series(events), cancelled: length(cancelled)}}
      end
    end
  end

  defp vevent_count(content), do: length(:binary.matches(content, "BEGIN:VEVENT"))

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
  in which case it stops and names the reason under `:halted`. After
  #{@max_failures_in_a_row} failures in a row it stops as `:unavailable`.

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
      halted: nil,
      failed_in_a_row: 0
    }

    summary =
      events
      |> Enum.with_index(1)
      |> Enum.reduce_while(initial, fn {event, done}, acc ->
        acc = write_event(event, target, acc)
        on_progress.(done)
        if acc.halted, do: {:halt, acc}, else: {:cont, acc}
      end)

    summary
    |> Map.delete(:failed_in_a_row)
    |> Map.update!(:failed_titles, &Enum.reverse/1)
  end

  @doc """
  Runs `fun` as the user's only import, or returns `{:error, :already_running}`
  while another of theirs is under way, from any tab or session.

  The claim is a global name held by the calling process, so it lapses with
  that process even when it crashes.
  """
  @spec exclusively(pos_integer(), (-> result)) :: result | {:error, import_error()}
        when result: term()
  def exclusively(user_id, fun) do
    name = lock_name(user_id)

    case :global.register_name(name, self()) do
      :yes ->
        try do
          fun.()
        after
          :global.unregister_name(name)
        end

      :no ->
        {:error, :already_running}
    end
  end

  @doc "Whether an import of the user's is under way."
  @spec running?(pos_integer()) :: boolean()
  def running?(user_id), do: :global.whereis_name(lock_name(user_id)) != :undefined

  defp lock_name(user_id), do: {__MODULE__, user_id}

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

  # The parser reads a floating time as UTC. Its wall clock is the one meant,
  # so it is placed in `zone` instead, along with the series' exclusions, which
  # RFC 5545 has written in the same value type as its DTSTART. The zone then
  # stands as the series' own, so its overrides resolve in it too.
  defp anchor_floating(%{floating: true} = raw, zone) do
    %{
      raw
      | start_time: wall_clock_in(raw.start_time, zone),
        end_time: wall_clock_in(raw.end_time, zone),
        exdates: Enum.map(raw.exdates || [], &wall_clock_in(&1, zone)),
        timezone: zone
    }
  end

  defp anchor_floating(raw, _zone), do: raw

  defp wall_clock_in(%DateTime{} = read_as_utc, zone) do
    case DateTime.from_naive(DateTime.to_naive(read_as_utc), zone) do
      {:ok, local} -> DateTime.shift_zone!(local, @utc)
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, @utc)
      {:gap, _before, just_after} -> DateTime.shift_zone!(just_after, @utc)
      {:error, _reason} -> read_as_utc
    end
  end

  defp wall_clock_in(other, _zone), do: other

  defp cancelled?(raw), do: String.upcase(raw[:status] || "") == "CANCELLED"

  # See `IcsImport.Series` for how overrides change the series they belong to.
  defp build_events(live, cancelled) do
    live
    |> Series.resolve(cancelled)
    |> Enum.map(fn {raw, rule, exclusions} -> event_data(raw, rule, exclusions) end)
  end

  defp event_data(raw, rule, exclusions) do
    all_day = is_struct(raw.start_time, Date)
    zone = known_zone(raw[:timezone])

    Map.reject(
      %{
        summary: clean_text(raw[:summary]) || "",
        description: clean_text(raw[:description]),
        location: clean_text(raw[:location]),
        start_time: raw.start_time,
        end_time: end_time(raw.start_time, raw.end_time, zone),
        all_day: all_day,
        timezone: if(all_day, do: zone, else: zone || @utc),
        recurrence_rule: rule,
        recurrence_exceptions: exclusions,
        transparency: transparency(raw[:transparency])
      },
      fn {_key, value} -> value in [nil, []] end
    )
  end

  # PostgreSQL rejects a null byte, which is valid UTF-8 and would otherwise
  # reach the cached copy of the event the next sync reads back.
  defp clean_text(nil), do: nil
  defp clean_text(text), do: String.replace(text, "\x00", "")

  # The parser keeps a TZID the database does not know, resolved through the
  # file's own VTIMEZONE; the times are already UTC, and a provider would only
  # refuse the name.
  defp known_zone(zone) when is_binary(zone), do: if(Timezones.valid?(zone), do: zone)
  defp known_zone(_zone), do: nil

  # A DTEND must share its DTSTART's value type, but files in the wild mix
  # them, and every provider's builder assumes they match. An end that is not
  # after the start falls back to the length the parser gives a bare start.
  defp end_time(%Date{} = start, end_value, zone) do
    case end_value && to_date(end_value, zone) do
      %Date{} = end_date ->
        if Date.after?(end_date, start), do: end_date, else: Date.add(start, 1)

      nil ->
        Date.add(start, 1)
    end
  end

  defp end_time(%DateTime{} = start, end_value, zone) do
    case end_value && to_datetime(end_value, zone) do
      %DateTime{} = end_at -> if DateTime.after?(end_at, start), do: end_at, else: start
      nil -> start
    end
  end

  defp to_date(%Date{} = date, _zone), do: date

  defp to_date(%DateTime{} = at, zone),
    do: at |> DateTime.shift_zone!(zone || @utc) |> DateTime.to_date()

  defp to_datetime(%DateTime{} = at, _zone), do: at

  defp to_datetime(%Date{} = date, zone),
    do: wall_clock_in(DateTime.new!(date, ~T[00:00:00]), zone || @utc)

  defp transparency("transparent"), do: :transparent
  defp transparency("opaque"), do: :opaque
  defp transparency(_other), do: nil

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

    case create_event(data, integration, target.user_id) do
      {:ok, _created} ->
        %{
          acc
          | created: acc.created + 1,
            failed_in_a_row: 0,
            exclusions_dropped: acc.exclusions_dropped + dropped_exclusions(event, integration)
        }

      {:error, reason} ->
        in_a_row = acc.failed_in_a_row + 1

        %{
          acc
          | failed: acc.failed + 1,
            failed_in_a_row: in_a_row,
            failed_titles: sample_title(acc.failed_titles, event.summary),
            halted: halt_reason(reason, in_a_row)
        }
    end
  end

  defp halt_reason(reason, _in_a_row) when reason in @fatal_errors, do: reason
  defp halt_reason(_reason, in_a_row) when in_a_row >= @max_failures_in_a_row, do: :unavailable
  defp halt_reason(_reason, _in_a_row), do: nil

  # One event a provider or builder cannot cope with is one failed event, not
  # the end of an import that has already written the events before it.
  defp create_event(data, integration, user_id) do
    CalendarEvents.create_event(data, {integration.id, user_id})
  rescue
    exception ->
      Logger.error("ICS import could not write an event",
        user_id: user_id,
        integration_id: integration.id,
        error: LogFormat.reason(exception),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      {:error, :crashed}
  end

  defp dropped_exclusions(%{recurrence_exceptions: [_one | _more]}, %{provider: "outlook"}), do: 1
  defp dropped_exclusions(_event, _integration), do: 0

  defp sample_title(titles, title) when length(titles) < @failed_sample_size,
    do: [title | titles]

  defp sample_title(titles, _title), do: titles
end

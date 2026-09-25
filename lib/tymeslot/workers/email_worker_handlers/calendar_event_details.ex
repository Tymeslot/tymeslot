defmodule Tymeslot.Workers.EmailWorkerHandlers.CalendarEventDetails do
  @moduledoc """
  Builds what the calendar invitation and event update emails say about an
  event: its timing, and for an update the list of changes to announce.

  ## Timed and all-day events

  The two carry different fields and the emails have to read the right ones.
  A timed event has `start_at`/`end_at` instants and a duration in minutes; an
  all-day event has `start_date` and an exclusive `end_date` (the iCal
  convention, see `Tymeslot.CalendarGrid.AllDay`) and no clock time at all.
  Every details map carries `:all_day` so the templates can dispatch on it,
  plus the fields of whichever representation applies:

    * timed: `:start_time`, `:end_time`, `:duration` (minutes), `:date`
    * all-day: `:start_date`, `:end_date` (exclusive), `:last_date`
      (inclusive, for display), `:date`; `:start_time`, `:end_time` and
      `:duration` are `nil`

  ## First notifications

  An event that has never been notified has no recorded baseline, so the job
  carries `"first_notification" => true` and no `before_*` values. There is
  nothing to compare against, so the change list states every populated field
  as it is now, with `nil` where the previous value would go, and the
  template renders it as the event's current details rather than a diff. The
  time is always part of that list, so a first notification never comes out
  empty. Jobs enqueued before the flag existed have no such key and diff
  exactly as they always did.
  """

  alias Tymeslot.CalendarGrid.AllDay

  @typedoc "One announced change: the field, its previous value (nil when unknown) and its current one."
  @type change :: {:title | :location | :description | :time, term(), term()}

  @doc "Invitation details from the job args of a `send_calendar_invitation` job."
  @spec invitation_details(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def invitation_details(user, args) do
    with {:ok, timing} <- invitation_timing(args) do
      {:ok,
       Map.merge(timing, %{
         event_title: args["event_title"],
         event_uid: args["event_uid"],
         location: args["event_location"],
         description: args["event_description"],
         organizer_name: user.name || user.email,
         organizer_email: user.email
       })}
    end
  end

  @doc """
  The changes an update notification announces, diffed from the job's
  `before_*` args against the cached event, or stated outright for a first
  notification (see the moduledoc).
  """
  @spec changes(map(), map()) :: [change()]
  def changes(current_event, args) do
    if first_notification?(args) do
      current_details(current_event)
    else
      []
      |> maybe_add_change(:title, args["before_title"], current_event.summary)
      |> maybe_add_change(:location, args["before_location"], current_event.location)
      |> maybe_add_change(:description, args["before_description"], current_event.description)
      |> maybe_add_time_change(args, current_event)
    end
  end

  @doc "Whether the job announces an event whose previous state was never recorded."
  @spec first_notification?(map()) :: boolean()
  def first_notification?(%{"first_notification" => true}), do: true
  def first_notification?(_args), do: false

  @doc """
  Update details for the cached event. `{:error, :no_timing}` for a row that
  carries neither representation's fields, which nothing can describe.
  """
  @spec update_details(map(), map(), [change()], map()) :: {:ok, map()} | {:error, :no_timing}
  def update_details(user, current_event, changes, args) do
    with {:ok, timing} <- event_timing(current_event) do
      {:ok,
       Map.merge(timing, %{
         event_title: current_event.summary,
         event_uid: current_event.uid,
         location: current_event.location,
         description: current_event.description,
         organizer_name: user.name || user.email,
         organizer_email: user.email,
         changes: changes,
         first_notification: first_notification?(args),
         method: parse_method(args["method"]),
         sequence: args["sequence"]
       })}
    end
  end

  defp invitation_timing(%{"event_all_day" => true} = args) do
    with {:ok, start_date} <- parse_date(args["event_start_date"]),
         {:ok, end_date} <- parse_date(args["event_end_date"]) do
      {:ok, all_day_timing(start_date, end_date)}
    end
  end

  defp invitation_timing(args) do
    with {:ok, start_time} <- parse_datetime(args["event_start_at"]),
         {:ok, end_time} <- parse_datetime(args["event_end_at"]) do
      {:ok, timed_timing(start_time, end_time)}
    end
  end

  defp event_timing(%{
         all_day: true,
         start_date: %Date{} = start_date,
         end_date: %Date{} = end_date
       }),
       do: {:ok, all_day_timing(start_date, end_date)}

  defp event_timing(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}),
    do: {:ok, timed_timing(start_at, end_at)}

  defp event_timing(_event), do: {:error, :no_timing}

  defp timed_timing(start_time, end_time) do
    %{
      all_day: false,
      start_time: start_time,
      end_time: end_time,
      date: DateTime.to_date(start_time),
      duration: DateTime.diff(end_time, start_time, :minute),
      start_date: nil,
      end_date: nil,
      last_date: nil
    }
  end

  defp all_day_timing(start_date, end_date) do
    %{
      all_day: true,
      start_time: nil,
      end_time: nil,
      date: start_date,
      duration: nil,
      start_date: start_date,
      end_date: end_date,
      last_date: AllDay.last_day(start_date, end_date)
    }
  end

  # Invitations enqueued before all-day events were supported carry nil
  # timestamps for one. Reading nil as a malformed value discards the job,
  # which is what the old crash ended in anyway, without five raising retries.
  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, "Invalid datetime: #{iso}"}
    end
  end

  defp parse_datetime(other), do: {:error, "Invalid datetime: #{inspect(other)}"}

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "Invalid datetime: #{iso}"}
    end
  end

  defp parse_date(other), do: {:error, "Invalid datetime: #{inspect(other)}"}

  defp current_details(current_event) do
    fields =
      for {field, current} <- [
            title: current_event.summary,
            location: current_event.location,
            description: current_event.description
          ],
          normalise_blank(current) != nil,
          do: {field, nil, current}

    case moment(current_event) do
      {:ok, current} -> [{:time, nil, display_moment(current)} | fields]
      :error -> fields
    end
  end

  defp maybe_add_change(changes, field, before_val, current_val) do
    if normalise_blank(before_val) != normalise_blank(current_val) do
      [{field, before_val, current_val} | changes]
    else
      changes
    end
  end

  # Compares whichever representation each side carries, so an event moved to
  # other days, retimed, or toggled between all-day and timed all read as a
  # time change. A job without a usable `before` pair (a baseline recorded
  # before its timing was, or before all-day dates were) announces none.
  defp maybe_add_time_change(changes, args, current_event) do
    with {:ok, before} <- before_moment(args),
         {:ok, current} <- moment(current_event),
         false <- same_moment?(before, current) do
      [{:time, display_moment(before), display_moment(current)} | changes]
    else
      _unchanged_or_unknown -> changes
    end
  end

  defp before_moment(%{"before_start_at" => start_at, "before_end_at" => end_at})
       when is_binary(start_at) and is_binary(end_at) do
    with {:ok, start_dt, _offset} <- DateTime.from_iso8601(start_at),
         {:ok, end_dt, _offset} <- DateTime.from_iso8601(end_at) do
      {:ok, {:timed, start_dt, end_dt}}
    else
      _invalid -> :error
    end
  end

  defp before_moment(%{"before_start_date" => start_date, "before_end_date" => end_date})
       when is_binary(start_date) and is_binary(end_date) do
    with {:ok, start_d} <- Date.from_iso8601(start_date),
         {:ok, end_d} <- Date.from_iso8601(end_date) do
      {:ok, {:all_day, start_d, end_d}}
    else
      _invalid -> :error
    end
  end

  defp before_moment(_args), do: :error

  defp moment(%{all_day: true, start_date: %Date{} = start_date, end_date: %Date{} = end_date}),
    do: {:ok, {:all_day, start_date, end_date}}

  defp moment(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}),
    do: {:ok, {:timed, start_at, end_at}}

  defp moment(_event), do: :error

  defp same_moment?({:timed, start_a, end_a}, {:timed, start_b, end_b}),
    do: DateTime.compare(start_a, start_b) == :eq and DateTime.compare(end_a, end_b) == :eq

  defp same_moment?({:all_day, start_a, end_a}, {:all_day, start_b, end_b}),
    do: Date.compare(start_a, start_b) == :eq and Date.compare(end_a, end_b) == :eq

  defp same_moment?(_before, _current), do: false

  # What the email shows for a moment: a timed event's start instant (as it
  # always has), an all-day event's inclusive range of days.
  defp display_moment({:timed, start_at, _end_at}), do: start_at

  defp display_moment({:all_day, start_date, end_date}),
    do: Date.range(start_date, AllDay.last_day(start_date, end_date))

  defp parse_method("cancel"), do: :cancel
  defp parse_method("request"), do: :request
  defp parse_method(_other), do: :request

  defp normalise_blank(nil), do: nil
  defp normalise_blank(""), do: nil
  defp normalise_blank(val), do: val
end

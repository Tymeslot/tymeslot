defmodule Tymeslot.Integrations.Calendar.Google.SeriesExceptions do
  @moduledoc """
  The occurrences of a Google series edited or cancelled on their own,
  carried to the tail of a split (see `Recurrence.SplitExceptions`).

  Google keeps each as an event of its own naming the master in
  `recurringEventId`, with its slot in `originalStartTime`; a cancelled one
  is such an event with `status` `cancelled`. They share the master's
  `iCalUID`, so one listing by it, unexpanded and with cancelled events,
  holds them all (`list_series_events/3`). It is read before the split is
  written, since Google drops them once the master ends before them.

  The tail's occurrence at a target is addressed by its instance id, the
  tail's id followed by its original start (`<id>_YYYYMMDD` for an all-day
  series, `<id>_YYYYMMDDTHHMMSSZ` in UTC for a timed one), which Google
  answers for as soon as the tail exists. An edited occurrence is written
  there with a patch of what it had of its own; a cancelled one by deleting
  it, which Google records as a cancelled occurrence. The tail may already
  lack a cancelled occurrence (an `EXDATE` the split carried), and it
  lacks every target a new rule no longer makes: Google answers those with
  a 404, which is `:unmatched`.
  """

  alias Tymeslot.Integrations.Calendar.Google.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Google.SeriesPatch
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit
  alias Tymeslot.Integrations.Calendar.Recurrence.SplitExceptions

  # The fields that are the occurrence's place in the series or Google's
  # own, rather than something it was given; timing is carried apart.
  @not_fields ~w(start end recurrence status conferenceData)

  # What a field the occurrence cleared is written as.
  @cleared %{"summary" => "", "description" => "", "location" => ""}

  @doc """
  Reads the exceptions of `master`, the series' master as Google returned
  it, from `calendar_id` through `api`, and plans their carry to the tail
  of a split by `edit` (see `Recurrence.SeriesMove.edit/0`, with `:slot`).
  A master without an `iCalUID` has none that can be found.
  """
  @spec plan(module(), map(), String.t(), map(), SeriesMove.edit()) ::
          {:ok, [SplitExceptions.carry()]} | {:error, term()} | {:error, atom(), String.t()}
  def plan(api, integration, calendar_id, master, edit) do
    with {:ok, timing, zone} <- SeriesPatch.master_timing(master),
         {:ok, slot} <- SeriesSplit.slot_wall(edit.slot, timing, zone),
         {:ok, move} <- SeriesMove.move(edit, timing, zone),
         {:ok, events} <- list(api, integration, calendar_id, master["iCalUID"]) do
      exceptions = Enum.flat_map(events, &exception(&1, master, timing, zone))
      {:ok, SplitExceptions.plan(exceptions, slot, timing, move)}
    end
  end

  defp list(api, integration, calendar_id, ical_uid) when is_binary(ical_uid),
    do: api.list_series_events(integration, calendar_id, ical_uid)

  defp list(_api, _integration, _calendar_id, _no_uid), do: {:ok, []}

  @doc """
  Writes `carries` to the tail `tail_id` of the split `master`, in
  `calendar_id` through `api`. See `Recurrence.SplitExceptions.carry/2`.
  """
  @spec carry(module(), map(), String.t(), map(), String.t(), [SplitExceptions.carry()]) ::
          map()
  def carry(api, integration, calendar_id, master, tail_id, carries) do
    {:ok, _timing, zone} = SeriesPatch.master_timing(master)

    SplitExceptions.carry(carries, fn %{target: target, change: change} ->
      id = instance_id(tail_id, target, zone)

      case change do
        :cancelled ->
          outcome(api.delete_event(integration, calendar_id, id))

        {:edited, fields, timing} ->
          outcome(api.patch_event(integration, calendar_id, id, body(fields, timing, zone)))
      end
    end)
  end

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _event}), do: :ok
  defp outcome({:error, :not_found, _message}), do: :unmatched
  defp outcome(error), do: {:error, error}

  # --- Reading ---

  defp exception(%{"recurringEventId" => id} = event, %{"id" => id} = master, timing, zone) do
    with {:ok, slot} <- wall(event["originalStartTime"], timing, zone),
         {:ok, change} <- change(event, master, timing, zone) do
      [%{slot: slot, change: change}]
    else
      _unreadable -> []
    end
  end

  defp exception(_other_event, _master, _timing, _zone), do: []

  defp change(%{"status" => "cancelled"}, _master, _timing, _zone), do: {:ok, :cancelled}

  defp change(event, master, timing, zone) do
    with {:ok, start} <- wall(event["start"], timing, zone),
         {:ok, finish} <- wall(event["end"], timing, zone),
         do: {:ok, {:edited, own_fields(event, master), {start, finish}}}
  end

  # A value of `start`, `end` or `originalStartTime` on the series' wall
  # clock, in the series' value type.
  defp wall(%{"date" => date}, timing, zone) do
    with {:ok, date} <- Date.from_iso8601(date), do: SeriesSplit.slot_wall(date, timing, zone)
  end

  defp wall(%{"dateTime" => value}, timing, zone) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> SeriesSplit.slot_wall(instant, timing, zone)
      {:error, _reason} -> {:error, :unreadable_timing}
    end
  end

  defp wall(_value, _timing, _zone), do: {:error, :unreadable_timing}

  # The fields the occurrence has that the master does not, or that it
  # cleared. Guests are compared by who they are: each occurrence keeps its
  # own replies.
  defp own_fields(event, master) do
    own = fields(event)
    base = fields(master)

    (Map.keys(own) ++ Map.keys(base))
    |> Enum.uniq()
    |> Enum.reject(&(comparable(own, &1) == comparable(base, &1)))
    |> Map.new(&{&1, Map.get(own, &1, Map.get(@cleared, &1))})
  end

  defp fields(event), do: event |> CreatableEvent.from_event() |> Map.drop(@not_fields)

  defp comparable(fields, "attendees"),
    do:
      fields
      |> Map.get("attendees", [])
      |> Enum.map(&String.downcase(&1["email"] || ""))
      |> Enum.sort()

  defp comparable(fields, key), do: Map.get(fields, key)

  # --- Writing ---

  defp instance_id(tail_id, %Date{} = date, _zone),
    do: tail_id <> "_" <> Calendar.strftime(date, "%Y%m%d")

  defp instance_id(tail_id, wall, zone) do
    instant = wall |> SeriesSplit.boundary(zone) |> DateTime.shift_zone!("Etc/UTC")
    tail_id <> "_" <> Calendar.strftime(instant, "%Y%m%dT%H%M%SZ")
  end

  defp body(fields, nil, _zone), do: fields

  defp body(fields, {%Date{} = start, finish}, _zone),
    do:
      Map.merge(fields, %{
        "start" => %{"date" => Date.to_iso8601(start)},
        "end" => %{"date" => Date.to_iso8601(finish)}
      })

  defp body(fields, {start, finish}, zone),
    do:
      Map.merge(fields, %{
        "start" => %{"dateTime" => NaiveDateTime.to_iso8601(start), "timeZone" => zone},
        "end" => %{"dateTime" => NaiveDateTime.to_iso8601(finish), "timeZone" => zone}
      })
end

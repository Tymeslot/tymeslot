defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesExceptions do
  @moduledoc """
  The occurrences of an Outlook series edited or cancelled on their own,
  carried to the tail of a split (see `Recurrence.SplitExceptions`).

  Graph lists them on the series master, read with `get_series_exceptions/2`
  before the split is written, since Graph drops them once the master's
  range ends before them: `exceptionOccurrences`, each an event with its
  slot in `originalStart`, and `cancelledOccurrences`, each an occurrence id
  ending in the date of its slot (`OID.{masterId}.{yyyy-MM-dd}`), which is
  at the master's time of day, since a Graph pattern repeats at most daily.

  The tail's occurrences have ids of their own, so the one at a target is
  found among the tail's instances around it by its `originalStart`
  (`list_instances/4`); the tail has none there when the edit gave it a new
  rule that no longer makes the target, which is `:unmatched`. An edited
  occurrence is written there with a patch of what it had of its own, and a
  cancelled one by deleting it, which cancels that occurrence.
  """

  alias Tymeslot.Integrations.Calendar.Outlook.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesPatch
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit
  alias Tymeslot.Integrations.Calendar.Recurrence.SplitExceptions

  @doc """
  Reads the exceptions of `master`, the series master as Graph returned it,
  through `api`, and plans their carry to the tail of a split by `edit`
  (see `Recurrence.SeriesMove.edit/0`, with `:slot`).
  """
  @spec plan(module(), map(), map(), SeriesMove.edit()) ::
          {:ok, [SplitExceptions.carry()]} | {:error, term()} | {:error, atom(), String.t()}
  def plan(api, integration, master, edit) do
    with {:ok, timing, zones} <- SeriesPatch.master_timing(master),
         clock = clock(master, timing, zones),
         {:ok, slot} <- SeriesSplit.slot_wall(edit.slot, timing, clock.zone),
         {:ok, move} <- SeriesMove.move(edit, timing, elem(zones, 0)),
         {:ok, series} <- api.get_series_exceptions(integration, edit.master_id) do
      exceptions =
        Enum.flat_map(series["exceptionOccurrences"] || [], &edited(&1, master, clock)) ++
          Enum.flat_map(series["cancelledOccurrences"] || [], &cancelled(&1, clock))

      {:ok, SplitExceptions.plan(exceptions, slot, timing, move)}
    end
  end

  @doc """
  Writes `carries` to the tail `tail_id` of the split `master` through
  `api`. See `Recurrence.SplitExceptions.carry/2`.
  """
  @spec carry(module(), map(), map(), String.t(), [SplitExceptions.carry()]) :: map()
  def carry(api, integration, master, tail_id, carries) do
    {:ok, timing, zones} = SeriesPatch.master_timing(master)
    clock = clock(master, timing, zones)

    SplitExceptions.carry(carries, fn %{target: target, change: change} ->
      case find_instance(api, integration, tail_id, target, clock) do
        {:ok, %{"id" => id}} -> write(api, integration, id, change, clock)
        other -> other
      end
    end)
  end

  # The series' wall clock: its timing's value type, the zone its slots are
  # read in (an all-day series' days in the zone it was created in), and the
  # label its timing is written with.
  defp clock(master, timing, {zone, label}) do
    day_zone = SeriesPatch.known_zone(master["originalStartTimeZone"])
    %{timing: timing, zone: zone || day_zone || "Etc/UTC", label: label}
  end

  # --- Reading ---

  defp edited(exception, master, clock) do
    own_zone = %{
      "originalStartTimeZone" => master["originalStartTimeZone"],
      "isAllDay" => master["isAllDay"]
    }

    with {:ok, slot} <- slot(exception["originalStart"], clock),
         {:ok, timing, _zones} <- SeriesPatch.master_timing(Map.merge(exception, own_zone)),
         true <- same_type?(slot, elem(timing, 0)) do
      [%{slot: slot, change: {:edited, own_fields(exception, master), timing}}]
    else
      _unreadable -> []
    end
  end

  defp cancelled(occurrence_id, %{timing: {start, _finish}}) when is_binary(occurrence_id) do
    with date when is_binary(date) <- occurrence_id |> String.split(".") |> List.last(),
         {:ok, date} <- Date.from_iso8601(date) do
      slot =
        case start do
          %Date{} -> date
          wall -> NaiveDateTime.new!(date, NaiveDateTime.to_time(wall))
        end

      [%{slot: slot, change: :cancelled}]
    else
      _unreadable -> []
    end
  end

  defp cancelled(_occurrence_id, _clock), do: []

  # An `originalStart`, a UTC instant, on the series' wall clock.
  defp slot(value, clock) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> SeriesSplit.slot_wall(instant, clock.timing, clock.zone)
      {:error, _reason} -> {:error, :unreadable_timing}
    end
  end

  defp slot(_value, _clock), do: {:error, :unreadable_timing}

  defp same_type?(%Date{}, %Date{}), do: true
  defp same_type?(%NaiveDateTime{}, %NaiveDateTime{}), do: true
  defp same_type?(_slot, _start), do: false

  # The writable fields the occurrence has that differ from the master's.
  # Guests are compared as `CreatableEvent` copies them, without replies,
  # and bodies as both are read, in the format they are stored in.
  defp own_fields(exception, master) do
    base = fields(master)

    exception
    |> fields()
    |> Enum.reject(fn {key, value} -> Map.get(base, key) == value end)
    |> Map.new()
  end

  defp fields(event), do: event |> CreatableEvent.from_event() |> Map.delete("isAllDay")

  # --- Writing ---

  # The tail's instances within a day of the target, so each is found
  # whatever its zone; the one whose original start is the target.
  defp find_instance(api, integration, tail_id, target, clock) do
    instant = instant(target, clock.zone)

    case api.list_instances(
           integration,
           tail_id,
           DateTime.add(instant, -1, :day),
           DateTime.add(instant, 1, :day)
         ) do
      {:ok, instances} ->
        case Enum.find(instances, &(slot(&1["originalStart"], clock) == {:ok, target})) do
          nil -> :unmatched
          instance -> {:ok, instance}
        end

      error ->
        {:error, error}
    end
  end

  defp instant(%Date{} = date, zone),
    do: SeriesSplit.boundary(NaiveDateTime.new!(date, ~T[00:00:00]), zone)

  defp instant(wall, zone), do: SeriesSplit.boundary(wall, zone)

  defp write(api, integration, id, :cancelled, _clock),
    do: outcome(api.delete_event(integration, id))

  defp write(api, integration, id, {:edited, fields, nil}, _clock),
    do: outcome(api.patch_event(integration, id, fields))

  defp write(api, integration, id, {:edited, fields, timing}, clock),
    do:
      outcome(
        api.patch_event(integration, id, CreatableEvent.put_timing(fields, timing, clock.label))
      )

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _event}), do: :ok
  defp outcome({:error, :not_found, _message}), do: :unmatched
  defp outcome(error), do: {:error, error}
end

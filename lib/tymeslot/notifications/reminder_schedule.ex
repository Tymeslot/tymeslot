defmodule Tymeslot.Notifications.ReminderSchedule do
  @moduledoc """
  What a meeting reminds with, and how far those reminders have got.

  A booking carries its own reminder list, copied from the meeting type at
  booking time — so the meeting type's current setting is not the answer for a
  booking made before it changed, and a meeting quick-added without one has no
  meeting type to ask at all. This module is the one place that reads the
  meeting's own column, including the legacy shapes older rows still carry, so
  what a surface *shows* and what `Orchestrator` *schedules* cannot drift
  apart.

  `nil` and `[]` are different answers: an empty list is a booking that asked
  for no reminders, while `nil` is a row from before the column existed, which
  falls back to the legacy fields and finally to 30 minutes — exactly the
  reminder such a booking actually receives.
  """

  alias Tymeslot.Utils.ReminderUtils

  @legacy_default "30 minutes"

  @type reminder :: %{value: pos_integer(), unit: String.t()}
  @type status :: %{value: pos_integer(), unit: String.t(), sent?: boolean()}

  @doc """
  The reminders a meeting is scheduled with, in the order they were configured.
  """
  @spec configured(%{atom() => term()}) :: [reminder()]
  def configured(meeting) do
    case Map.get(meeting, :reminders) do
      nil -> [legacy_reminder(meeting)]
      reminders -> ReminderUtils.normalize_reminders(reminders)
    end
  end

  @doc """
  The same reminders, each carrying whether its email has already gone out.

  A reminder counts as sent once `reminders_sent` records it reaching the
  organiser or the attendee. Guests are stamped per guest rather than on the
  meeting, so a reminder shown as sent says nothing about whether every guest
  was reached — only that the reminder fired.
  """
  @spec with_status(%{atom() => term()}) :: [status()]
  def with_status(meeting) do
    sent = meeting |> Map.get(:reminders_sent) |> List.wrap()

    Enum.map(configured(meeting), fn reminder ->
      Map.put(reminder, :sent?, sent?(sent, reminder))
    end)
  end

  # --- Private helpers ---

  defp legacy_reminder(meeting) do
    label =
      Map.get(meeting, :reminder_time) || Map.get(meeting, :default_reminder_time) ||
        @legacy_default

    %{
      value: ReminderUtils.parse_reminder_value(label),
      unit: ReminderUtils.normalize_reminder_unit(label)
    }
  end

  defp sent?(entries, %{value: value, unit: unit}) do
    case Enum.find(entries, &entry_match?(&1, value, unit)) do
      nil ->
        false

      entry ->
        flag(entry, "organizer_sent", :organizer_sent) or
          flag(entry, "attendee_sent", :attendee_sent)
    end
  end

  defp entry_match?(entry, value, unit) do
    case entry do
      %{"value" => v, "unit" => u} -> v == value and u == unit
      %{value: v, unit: u} -> v == value and u == unit
      _other -> false
    end
  end

  # A pre-upsert entry carries no per-recipient flags. It is read as sent
  # rather than guessed at, the same way the reminder worker reads it: the
  # entry exists because the reminder fired.
  defp flag(entry, string_key, atom_key) do
    case entry do
      %{^string_key => sent} when is_boolean(sent) -> sent
      %{^atom_key => sent} when is_boolean(sent) -> sent
      _other -> true
    end
  end
end

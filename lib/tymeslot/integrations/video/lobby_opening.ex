defmodule Tymeslot.Integrations.Video.LobbyOpening do
  @moduledoc """
  When a video room's lobby lets guests in, for a meeting that starts at a
  given time or on a given day.

  A timed meeting's lobby opens at its start. An all-day meeting has no hour
  to wait for, so its lobby opens at the earliest moment its first day begins
  anywhere: 14 hours before midnight UTC, the offset of the earliest timezone.
  Opening it later than that would hold guests in a timezone already on that
  day outside a room they were invited to.

  The one place this rule lives: the calendar grid's record of a room and the
  providers that set a lobby timer both read it from here.
  """

  # The earliest any timezone starts a calendar day, relative to midnight UTC.
  @earliest_day_start_seconds -14 * 3600

  @doc """
  The moment the lobby opens for a meeting starting at `start`: a
  `DateTime`, a `NaiveDateTime` taken as UTC, or a `Date` for an all-day
  meeting. Always a UTC `DateTime` truncated to the second.
  """
  @spec opens_at(DateTime.t() | NaiveDateTime.t() | Date.t()) :: DateTime.t()
  def opens_at(%DateTime{} = start),
    do: start |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  def opens_at(%NaiveDateTime{} = start),
    do: start |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  def opens_at(%Date{} = day) do
    day
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(@earliest_day_start_seconds, :second)
  end
end

defmodule Tymeslot.Integrations.Calendar.FreebusyGenerator do
  @moduledoc """
  Builds an iCalendar `VFREEBUSY` document (RFC 5545 §3.6.4) publishing a
  user's busy intervals so external calendar systems can overlay their
  availability.

  Times are emitted in UTC with a `Z` suffix, matching the rest of Tymeslot's
  iCalendar emission policy (no `VTIMEZONE`). Each busy interval becomes a
  `FREEBUSY;FBTYPE=BUSY` line carrying an RFC 5545 PERIOD (`start/end`).
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  @typedoc "A busy interval as a pair of UTC datetimes."
  @type interval :: {DateTime.t(), DateTime.t()}

  @doc """
  Renders a `VCALENDAR` wrapping a single `VFREEBUSY` component.

  ## Options
    * `:uid` — UID for the VFREEBUSY (defaults to a generated value)
    * `:window_start` / `:window_end` — the published period bounds (required)
    * `:intervals` — list of `{start_dt, end_dt}` busy intervals (defaults to `[]`)
    * `:organizer_email` — optional ORGANIZER mailto
  """
  @spec generate(keyword()) :: String.t()
  def generate(opts) do
    window_start = Keyword.fetch!(opts, :window_start)
    window_end = Keyword.fetch!(opts, :window_end)
    intervals = Keyword.get(opts, :intervals, [])
    uid = Keyword.get(opts, :uid) || ICalBuilder.generate_uid()

    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Tymeslot//Free/Busy//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "BEGIN:VFREEBUSY",
        "UID:#{uid}",
        "DTSTAMP:#{format(DateTime.utc_now())}",
        "DTSTART:#{format(window_start)}",
        "DTEND:#{format(window_end)}",
        organizer_line(Keyword.get(opts, :organizer_email))
      ] ++ Enum.map(intervals, &freebusy_line/1) ++ ["END:VFREEBUSY", "END:VCALENDAR"]

    lines
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp freebusy_line({start_dt, end_dt}) do
    "FREEBUSY;FBTYPE=BUSY:#{format(start_dt)}/#{format(end_dt)}"
  end

  defp organizer_line(email) when is_binary(email) and email != "" do
    "ORGANIZER:mailto:#{String.replace(email, ~r/[\r\n]/, "")}"
  end

  defp organizer_line(_other), do: nil

  defp format(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> ICalBuilder.format_datetime()
  end
end

defmodule Tymeslot.CalendarGrid.QuickAddParser do
  @moduledoc """
  Parses a single line of natural-language text into a structured event draft for
  the calendar quick-add input.

  This is a **pure** function: it never reads the wall clock. The caller supplies
  `:now` (a `DateTime`) and `:timezone` (an IANA name) so parsing is deterministic
  and testable. Construct times in the user's timezone, then convert to UTC for
  the returned `start_at`/`end_at`.

  Supported patterns (case-insensitive, order-independent within the line):

    * time-of-day — `3pm`, `3:30pm`, `15:00` → that time, default one-hour span
    * relative day — `today`, `tomorrow`, weekday names (`Thu`/`Thursday`)
    * duration — `for 30m`, `for 2h`
    * `all day` — produces a `start_date`/`end_date` draft with `all_day: true`

  Whatever text remains once the matched tokens are removed becomes the title. If
  nothing matches, the whole line is returned as the title with no time — the
  caller then opens the full create modal pre-filled with just that title.
  """

  defstruct title: "",
            start_at: nil,
            end_at: nil,
            start_date: nil,
            end_date: nil,
            all_day: false

  @type t :: %__MODULE__{
          title: String.t(),
          start_at: DateTime.t() | nil,
          end_at: DateTime.t() | nil,
          start_date: Date.t() | nil,
          end_date: Date.t() | nil,
          all_day: boolean()
        }

  @default_duration_minutes 60

  @weekdays %{
    "monday" => 1,
    "mon" => 1,
    "tuesday" => 2,
    "tue" => 2,
    "tues" => 2,
    "wednesday" => 3,
    "wed" => 3,
    "thursday" => 4,
    "thu" => 4,
    "thur" => 4,
    "thurs" => 4,
    "friday" => 5,
    "fri" => 5,
    "saturday" => 6,
    "sat" => 6,
    "sunday" => 7,
    "sun" => 7
  }

  @doc """
  Parses `text` into an event draft. See the module doc for supported patterns and
  the required `:now`/`:timezone` options.
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(text, opts) do
    now = Keyword.fetch!(opts, :now)
    timezone = Keyword.fetch!(opts, :timezone)
    today = DateTime.to_date(DateTime.shift_zone!(now, timezone))

    {text, all_day?} = extract_all_day(text)
    {text, date} = extract_date(text, today)
    {text, time} = extract_time(text)
    # A duration is only meaningful alongside a time-of-day; otherwise leave the
    # "for 30m" text in the title rather than silently dropping it.
    {text, duration} = if time, do: extract_duration(text), else: {text, nil}

    title = clean_title(text)

    build(%{
      title: title,
      all_day?: all_day?,
      date: date,
      time: time,
      duration: duration,
      timezone: timezone
    })
  end

  # --- assembly ----------------------------------------------------------------

  defp build(%{all_day?: true} = parsed) do
    date = parsed.date || nil

    %__MODULE__{
      title: parsed.title,
      all_day: true,
      start_date: date,
      end_date: date
    }
  end

  defp build(%{time: {hour, minute}} = parsed) do
    date = parsed.date
    duration = parsed.duration || @default_duration_minutes

    start_at = to_utc(date, hour, minute, parsed.timezone)
    end_at = DateTime.add(start_at, duration * 60, :second)

    %__MODULE__{title: parsed.title, start_at: start_at, end_at: end_at}
  end

  # A bare date with no time and not all-day is not actionable on a time grid;
  # fall through to a title-only draft so the caller opens the full modal.
  defp build(parsed), do: %__MODULE__{title: parsed.title}

  defp to_utc(date, hour, minute, timezone) do
    {:ok, dt} = DateTime.new(date, Time.new!(hour, minute, 0), timezone)
    DateTime.shift_zone!(dt, "Etc/UTC")
  end

  # --- all-day -----------------------------------------------------------------

  defp extract_all_day(text) do
    if Regex.match?(~r/\ball[\s-]?day\b/i, text) do
      {Regex.replace(~r/\ball[\s-]?day\b/i, text, " "), true}
    else
      {text, false}
    end
  end

  # --- date --------------------------------------------------------------------

  defp extract_date(text, today) do
    cond do
      Regex.match?(~r/\btomorrow\b/i, text) ->
        {strip(text, ~r/\btomorrow\b/i), Date.add(today, 1)}

      Regex.match?(~r/\btoday\b/i, text) ->
        {strip(text, ~r/\btoday\b/i), today}

      match = weekday_match(text) ->
        {word, weekday} = match
        {strip(text, ~r/\b#{word}\b/i), next_weekday(today, weekday)}

      true ->
        {text, today}
    end
  end

  defp weekday_match(text) do
    Enum.find_value(@weekdays, fn {word, weekday} ->
      if Regex.match?(~r/\b#{word}\b/i, text), do: {word, weekday}
    end)
  end

  # Resolve to the next date with the given ISO weekday that is strictly after
  # `today` — so naming today's weekday lands a full week ahead.
  defp next_weekday(today, weekday) do
    diff = rem(weekday - Date.day_of_week(today) + 7, 7)
    Date.add(today, if(diff == 0, do: 7, else: diff))
  end

  # --- duration ----------------------------------------------------------------

  defp extract_duration(text) do
    case Regex.run(~r/\bfor\s+(\d+)\s*(h|hr|hrs|hour|hours|m|min|mins|minutes?)\b/i, text) do
      [match, amount, unit] ->
        minutes = duration_to_minutes(String.to_integer(amount), unit)
        {String.replace(text, match, " "), minutes}

      nil ->
        {text, nil}
    end
  end

  defp duration_to_minutes(amount, unit) do
    if String.starts_with?(String.downcase(unit), "h"), do: amount * 60, else: amount
  end

  # --- time --------------------------------------------------------------------

  defp extract_time(text) do
    cond do
      match = Regex.run(~r/\b(\d{1,2}):(\d{2})\s*(am|pm)\b/i, text) ->
        [whole, h, m, meridiem] = match

        {strip_literal(text, whole),
         to_clock(String.to_integer(h), String.to_integer(m), meridiem)}

      match = Regex.run(~r/\b(\d{1,2})\s*(am|pm)\b/i, text) ->
        [whole, h, meridiem] = match
        {strip_literal(text, whole), to_clock(String.to_integer(h), 0, meridiem)}

      match = Regex.run(~r/\b(\d{1,2}):(\d{2})\b/, text) ->
        [whole, h, m] = match
        hour = String.to_integer(h)
        minute = String.to_integer(m)

        if valid_24h?(hour, minute) do
          {strip_literal(text, whole), {hour, minute}}
        else
          {text, nil}
        end

      true ->
        {text, nil}
    end
  end

  defp valid_24h?(hour, minute), do: hour <= 23 and minute <= 59

  defp to_clock(hour, minute, meridiem) do
    base = rem(hour, 12)

    hour24 =
      case String.downcase(meridiem) do
        "pm" -> base + 12
        "am" -> base
      end

    {hour24, minute}
  end

  # --- title -------------------------------------------------------------------

  defp clean_title(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip(text, regex), do: Regex.replace(regex, text, " ")

  # Replace the first literal occurrence of an already-matched substring.
  defp strip_literal(text, literal), do: String.replace(text, literal, " ", global: false)
end

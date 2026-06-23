defmodule Tymeslot.Integrations.Calendar.Recurrence.RRule do
  @moduledoc """
  Builds and parses RFC-5545 RRULE strings for the calendar grid's recurrence
  editor. Pure data transformations — no side effects.

  The supported surface matches the recurrence editor UI: a frequency
  (daily/weekly/monthly/yearly), an `INTERVAL` ("every N"), an optional `BYDAY`
  weekday selection for weekly rules, and one of two mutually-exclusive end
  conditions — `COUNT` (after N occurrences) or `UNTIL` (on a date). Complex
  rules (BYSETPOS, BYMONTH, multiple BYxxx parts) are intentionally out of
  scope; `parse/1` ignores tokens it does not understand rather than failing.

  The canonical option map shape used by both functions:

      %{
        freq: :daily | :weekly | :monthly | :yearly,
        interval: pos_integer() | nil,
        by_day: [:mo | :tu | :we | :th | :fr | :sa | :su],
        count: pos_integer() | nil,
        until: Date.t() | nil
      }
  """

  @type freq :: :daily | :weekly | :monthly | :yearly
  @type weekday :: :mo | :tu | :we | :th | :fr | :sa | :su
  @type opts :: %{
          optional(:freq) => freq(),
          optional(:interval) => pos_integer() | nil,
          optional(:by_day) => [weekday()],
          optional(:count) => pos_integer() | nil,
          optional(:until) => Date.t() | nil
        }

  @freq_to_token %{daily: "DAILY", weekly: "WEEKLY", monthly: "MONTHLY", yearly: "YEARLY"}
  @token_to_freq %{
    "DAILY" => :daily,
    "WEEKLY" => :weekly,
    "MONTHLY" => :monthly,
    "YEARLY" => :yearly
  }

  @weekday_to_token %{
    mo: "MO",
    tu: "TU",
    we: "WE",
    th: "TH",
    fr: "FR",
    sa: "SA",
    su: "SU"
  }
  @token_to_weekday Map.new(@weekday_to_token, fn {atom, token} -> {token, atom} end)

  @doc """
  Builds an RFC-5545 RRULE string from the canonical option map.

  Parts are emitted in a stable order: `FREQ`, `INTERVAL` (only when > 1),
  `BYDAY` (only when non-empty), then the end condition. `COUNT` wins over
  `UNTIL` when both are supplied. `UNTIL` is serialised as an end-of-day UTC
  timestamp so the supplied calendar date is fully included.
  """
  @spec build(opts()) :: String.t()
  def build(opts) do
    [
      build_freq(opts),
      build_interval(opts),
      build_by_day(opts),
      build_end_condition(opts)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(";")
  end

  @doc """
  Parses an RRULE string into the canonical option map.

  Lenient: a leading `RRULE:` prefix is stripped, unknown tokens are ignored,
  and only keys that are present in the string appear in the result.
  """
  @spec parse(String.t()) :: opts()
  def parse(rrule) when is_binary(rrule) do
    rrule
    |> strip_prefix()
    |> String.split(";", trim: true)
    |> Enum.reduce(%{}, &parse_token/2)
  end

  # --- build helpers ---

  defp build_freq(%{freq: freq}) when is_map_key(@freq_to_token, freq),
    do: "FREQ=#{@freq_to_token[freq]}"

  defp build_freq(_opts), do: nil

  defp build_interval(%{interval: interval}) when is_integer(interval) and interval > 1,
    do: "INTERVAL=#{interval}"

  defp build_interval(_opts), do: nil

  defp build_by_day(%{by_day: [_first | _rest] = days}) do
    tokens =
      days
      |> Enum.map(&Map.get(@weekday_to_token, &1))
      |> Enum.reject(&is_nil/1)

    if tokens == [], do: nil, else: "BYDAY=#{Enum.join(tokens, ",")}"
  end

  defp build_by_day(_opts), do: nil

  defp build_end_condition(%{count: count}) when is_integer(count) and count > 0,
    do: "COUNT=#{count}"

  defp build_end_condition(%{until: %Date{} = until}),
    do: "UNTIL=#{format_until(until)}"

  defp build_end_condition(_opts), do: nil

  defp format_until(%Date{} = date) do
    "#{pad(date.year, 4)}#{pad(date.month, 2)}#{pad(date.day, 2)}T235959Z"
  end

  defp pad(int, width), do: int |> Integer.to_string() |> String.pad_leading(width, "0")

  # --- parse helpers ---

  defp strip_prefix("RRULE:" <> rest), do: rest
  defp strip_prefix(rrule), do: rrule

  defp parse_token(token, acc) do
    case String.split(token, "=", parts: 2) do
      [key, value] -> apply_token(String.upcase(key), value, acc)
      _other -> acc
    end
  end

  defp apply_token("FREQ", value, acc) do
    case Map.get(@token_to_freq, String.upcase(value)) do
      nil -> acc
      freq -> Map.put(acc, :freq, freq)
    end
  end

  defp apply_token("INTERVAL", value, acc) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> Map.put(acc, :interval, int)
      _other -> acc
    end
  end

  defp apply_token("BYDAY", value, acc) do
    days =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&Map.get(@token_to_weekday, String.upcase(&1)))
      |> Enum.reject(&is_nil/1)

    if days == [], do: acc, else: Map.put(acc, :by_day, days)
  end

  defp apply_token("COUNT", value, acc) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> Map.put(acc, :count, int)
      _other -> acc
    end
  end

  defp apply_token("UNTIL", value, acc) do
    case parse_until(value) do
      {:ok, date} -> Map.put(acc, :until, date)
      :error -> acc
    end
  end

  defp apply_token(_unknown, _value, acc), do: acc

  defp parse_until(value) do
    with <<y::binary-4, m::binary-2, d::binary-2, _rest::binary>> <- String.slice(value, 0, 10),
         {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _other -> :error
    end
  end
end

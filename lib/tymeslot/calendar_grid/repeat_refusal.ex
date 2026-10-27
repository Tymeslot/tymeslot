defmodule Tymeslot.CalendarGrid.RepeatRefusal do
  @moduledoc """
  Whether a calendar would refuse a repeat rule before it is written, so the
  editor can say so while the organiser is still choosing the pattern.

  Only Outlook refuses rules: one Graph has no pattern for
  (`:rule_not_supported_by_outlook`), and a monthly or yearly series on a
  day some months lack (`:day_missing_in_some_months`; see
  `Outlook.RecurrenceConverter`). The check is the write's own conversion,
  from the start the rule is written against, read in the series' zone.
  """

  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter

  @type reason :: :rule_not_supported_by_outlook | :day_missing_in_some_months

  @doc """
  The reason a calendar of `provider` refuses `rule` for a series starting
  on `start_date`, or `nil` when it takes it.
  """
  @spec reason(atom() | String.t() | nil, String.t() | nil, Date.t(), String.t() | nil) ::
          reason() | nil
  def reason(provider, rule, %Date{} = start_date, timezone)
      when provider in ["outlook", :outlook] and is_binary(rule) do
    case RecurrenceConverter.rrule_to_outlook(rule, start_date, timezone) do
      {:error, reason} -> reason
      {:ok, _recurrence} -> nil
    end
  end

  def reason(_provider, _rule, _start_date, _timezone), do: nil
end

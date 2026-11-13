defmodule TymeslotWeb.Components.Shared.PickerPreferences do
  @moduledoc """
  The week start and clock the date and time pickers draw with, for the process
  rendering the page: the same way the Gettext locale reaches every component.

  They are facts about who is looking at the page, and a form field can sit
  many LiveComponents below the one place that knows them, so they are set once
  where the viewer is resolved (`DashboardInitHook`, `SchedulingInit`) rather
  than threaded through every parent. A picker given `week_start` or
  `time_format` directly uses those instead.

  With nothing set, a week starts on Monday and the clock follows the language,
  which is the rule for anyone who has not chosen.
  """

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  @week_start_key {__MODULE__, :week_start}
  @time_format_key {__MODULE__, :time_format}

  @doc "Sets the week start pickers rendered by this process use."
  @spec put_week_start(:monday | :sunday) :: :ok
  def put_week_start(week_start) when week_start in [:monday, :sunday] do
    Process.put(@week_start_key, week_start)
    :ok
  end

  @doc "Sets the clock pickers rendered by this process use."
  @spec put_time_format(String.t()) :: :ok
  def put_time_format(time_format) do
    Process.put(@time_format_key, time_format)
    :ok
  end

  @doc "The week start to draw with: `explicit` when given, else this process's."
  @spec week_start(:monday | :sunday | nil) :: :monday | :sunday
  def week_start(nil), do: Process.get(@week_start_key, :monday)
  def week_start(explicit) when explicit in [:monday, :sunday], do: explicit

  @doc "The clock to draw with: `explicit` when given, else this process's, else the language's."
  @spec time_format(String.t() | nil, String.t() | nil) :: String.t()
  def time_format(nil, locale), do: Process.get(@time_format_key) || TimeFormat.for_locale(locale)
  def time_format(explicit, _locale), do: explicit
end

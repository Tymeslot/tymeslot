defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SeriesHandlers do
  @moduledoc """
  The Series section's form state and its `update_series` event, kept apart
  from the markup in `SeriesSection`.

  The state is the `:series` assign, a map of the schema's series fields plus
  `:fixed` (whether the count is one number), built by `initial/1`. Clicks
  carry `series_action` (`toggle`, `mode`, `fixed`, `single`); the inputs post
  `series[...]`. A change is ignored without access
  (`recurring_bookings_allowed`) and for a mode the type's other settings rule
  out (`SeriesSettings.conflicts/1`), and otherwise auto-saves.
  `Tymeslot.MeetingTypes.FormValidation` refuses a forged one on save all
  the same.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes.SeriesSettings
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Autosave

  @default_min 4
  @default_max 8

  @series_fields [
    :series_mode,
    :series_frequency,
    :series_interval,
    :series_min_occurrences,
    :series_max_occurrences,
    :series_required
  ]

  @doc "The `:series` form state for a meeting type, or for a new one (`nil`)."
  @spec initial(map() | nil) :: map()
  def initial(type) do
    type = type || %{}
    min = Map.get(type, :series_min_occurrences) || @default_min
    max = Map.get(type, :series_max_occurrences) || @default_max

    %{
      series_mode: Map.get(type, :series_mode),
      series_frequency: Map.get(type, :series_frequency) || :weekly,
      series_interval: Map.get(type, :series_interval) || 1,
      series_min_occurrences: min,
      series_max_occurrences: max,
      series_required: Map.get(type, :series_required) != false,
      fixed: min == max
    }
  end

  @doc """
  Applies one `update_series` event to the form state and auto-saves. Ignored
  without access, and for a change the type's other settings rule out.
  """
  @spec apply_event(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def apply_event(_params, %{assigns: %{recurring_bookings_allowed: false}} = socket),
    do: socket

  def apply_event(params, %{assigns: assigns} = socket) do
    case change(assigns.series, params, settings(assigns)) do
      series when series == assigns.series ->
        socket

      series ->
        socket
        |> assign(:series, series)
        |> assign(:form_errors, Map.drop(assigns.form_errors, @series_fields))
        |> Autosave.maybe_run()
    end
  end

  defp change(series, %{"series_action" => "toggle"}, settings) do
    case series.series_mode do
      nil ->
        mode = Enum.find([:recurring, :flexible], &offerable?(settings, &1))
        %{series | series_mode: mode}

      _on ->
        %{series | series_mode: nil}
    end
  end

  defp change(%{series_mode: on} = series, %{"series_action" => "mode", "mode" => mode}, settings)
       when on != nil and mode in ~w(recurring flexible) do
    mode = String.to_existing_atom(mode)
    if offerable?(settings, mode), do: %{series | series_mode: mode}, else: series
  end

  defp change(series, %{"series_action" => "fixed"}, _settings) do
    fixed = not series.fixed
    max = if fixed, do: series.series_min_occurrences, else: series.series_max_occurrences
    %{series | fixed: fixed, series_max_occurrences: max}
  end

  defp change(series, %{"series_action" => "single"}, _settings),
    do: %{series | series_required: not series.series_required}

  defp change(series, %{"series" => inputs}, _settings) when is_map(inputs) do
    series = Enum.reduce(inputs, series, &put_input/2)

    if series.fixed,
      do: %{series | series_max_occurrences: series.series_min_occurrences},
      else: series
  end

  defp change(series, _params, _settings), do: series

  defp put_input({"frequency", value}, series) when value in ~w(daily weekly monthly),
    do: %{series | series_frequency: String.to_existing_atom(value)}

  defp put_input({"interval", value}, series) do
    interval = parse(value)

    if is_integer(interval) and interval in SeriesSettings.intervals(),
      do: %{series | series_interval: interval},
      else: series
  end

  # Counts outside the range are kept, so the changeset's error shows beside
  # what was typed; only text that is no number at all is dropped.
  defp put_input({"min", value}, series),
    do: put_count(series, :series_min_occurrences, parse(value))

  defp put_input({"max", value}, series),
    do: put_count(series, :series_max_occurrences, parse(value))

  defp put_input(_other, series), do: series

  defp put_count(series, field, count) when is_integer(count), do: Map.put(series, field, count)
  defp put_count(series, _field, _count), do: series

  defp parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _invalid -> nil
    end
  end

  defp parse(_value), do: nil

  # What `SeriesSettings.conflicts/1` reads, from the form's current state.
  defp settings(assigns) do
    type = assigns.type || %{}

    %{
      one_off: Map.get(type, :one_off) == true,
      invitation_only: Map.get(type, :invitation_only) == true,
      fixed_dates: Map.get(assigns, :fixed_dates) == true
    }
  end

  defp offerable?(settings, mode), do: mode_conflict(settings, mode) == nil

  # Why `mode` cannot be offered, translated, or nil when it can.
  defp mode_conflict(settings, mode) do
    case SeriesSettings.conflicts(Map.put(settings, :series_mode, mode)) do
      [] -> nil
      [{_field, message} | _rest] -> Gettext.dgettext(TymeslotWeb.Gettext, "errors", message)
    end
  end

  @doc """
  The booking limits too low for one series of this type, worded for the
  form. `booking_limits` is the form's string-keyed limits.
  """
  @spec limit_notes(map(), map()) :: [String.t()]
  def limit_notes(series, booking_limits) do
    series
    |> Map.merge(%{
      max_bookings_per_week: booking_limits["max_bookings_per_week"],
      max_bookings_per_month: booking_limits["max_bookings_per_month"]
    })
    |> SeriesSettings.limit_conflicts()
    |> Enum.map(&limit_note/1)
  end

  defp limit_note({:per_week, limit, needed}),
    do:
      dgettext(
        "dashboard_booking_series",
        "Your limit of %{limit} bookings per week is lower than the %{needed} sessions a series can book in one week, so some series won't fit.",
        limit: limit,
        needed: needed
      )

  defp limit_note({:per_month, limit, needed}),
    do:
      dgettext(
        "dashboard_booking_series",
        "Your limit of %{limit} bookings per month is lower than the %{needed} sessions a series can book in one month, so some series won't fit.",
        limit: limit,
        needed: needed
      )

  @doc "The schema fields the series state posts, which carry its errors."
  @spec fields() :: [atom()]
  def fields, do: @series_fields

  @doc """
  Why each mode cannot be offered with the form's other settings, translated,
  or nil where it can.
  """
  @spec mode_conflicts(map()) :: %{recurring: String.t() | nil, flexible: String.t() | nil}
  def mode_conflicts(assigns) do
    settings = settings(assigns)

    %{
      recurring: mode_conflict(settings, :recurring),
      flexible: mode_conflict(settings, :flexible)
    }
  end
end

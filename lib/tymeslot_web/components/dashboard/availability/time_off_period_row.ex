defmodule TymeslotWeb.Components.Dashboard.Availability.TimeOffPeriodRow do
  @moduledoc """
  One time-off period as a row of the availability page's time-off list,
  and the line describing when it runs, which the list row and the delete
  confirmation both show.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @doc """
  Renders one period, with its edit and remove buttons.

  A finished (`past`) period has no edit button: there is nothing left to
  move, since neither of its dates may be placed in the past again. It is
  removed in place rather than through the confirmation dialog.
  """
  attr :period, :any, required: true
  attr :time_format, :string, required: true
  attr :myself, :any, required: true
  attr :past, :boolean, default: false

  @spec period_row(map()) :: Phoenix.LiveView.Rendered.t()
  def period_row(assigns) do
    ~H"""
    <li
      id={row_id(@period, @past)}
      phx-remove={@past && row_removal()}
      class={[
        "flex flex-wrap items-center justify-between gap-3 rounded-token-xl border border-tymeslot-100 px-4 py-3",
        if(@past, do: "bg-white", else: "bg-tymeslot-50")
      ]}
    >
      <div class="min-w-0" data-strike>
        <p class={["font-bold", if(@past, do: "text-tymeslot-500", else: "text-tymeslot-700")]}>
          {range_summary(@period, @time_format)}
        </p>
        <p :if={@period.label} class="text-token-sm text-tymeslot-500 font-medium truncate">
          {@period.label}
        </p>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <Buttons.icon_button
          :if={not @past}
          icon="hero-pencil-square"
          label={dgettext("dashboard_availability_time_off", "Edit time off")}
          phx-click="show_time_off_form"
          phx-value-id={@period.id}
          phx-target={@myself}
        />
        <Buttons.icon_button
          icon="hero-trash"
          variant={:danger}
          label={dgettext("dashboard_availability_time_off", "Remove time off")}
          phx-click={
            if @past,
              do: remove_past(@period, @myself),
              else: JS.push("show_delete_time_off", value: %{id: @period.id}, target: @myself)
          }
        />
      </div>
    </li>
    """
  end

  defp row_id(period, true), do: "time-off-past-#{period.id}"
  defp row_id(period, false), do: "time-off-#{period.id}"

  # Crossed out at once, then removed by the server: the row's `phx-remove`
  # fades it once the re-render drops it, after a short pause so the line
  # through it registers first.
  defp remove_past(period, myself) do
    row = "#" <> row_id(period, true)

    "line-through decoration-2 decoration-tymeslot-400"
    |> JS.add_class(to: "#{row} [data-strike]")
    |> JS.add_class("pointer-events-none", to: row)
    |> JS.push("delete_past_time_off", value: %{id: period.id}, target: myself)
  end

  defp row_removal do
    JS.hide(
      transition:
        {"transition-all duration-700 delay-500 ease-in", "opacity-100 translate-x-0",
         "opacity-0 translate-x-6"},
      time: 1200
    )
  end

  @doc """
  One line describing when a period runs, as the list row and the delete
  confirmation both show it.

  A whole-day period reads as dates alone; the times appear only where they
  actually trim a day, so a plain holiday is not dressed up as "00:00 to
  23:59".
  """
  @spec range_summary(TimeOff.period(), String.t()) :: String.t()
  def range_summary(period, time_format) do
    period
    |> dates_summary()
    |> append_time(period.start_time, time_format, :from)
    |> append_time(period.end_time, time_format, :until)
  end

  defp dates_summary(%{starts_on: same, ends_on: same}),
    do: LocalizationHelpers.format_date(same)

  defp dates_summary(%{starts_on: starts_on, ends_on: ends_on}) do
    dgettext("dashboard_availability_time_off", "%{from} to %{to}",
      from: LocalizationHelpers.format_date(starts_on),
      to: LocalizationHelpers.format_date(ends_on)
    )
  end

  defp append_time(summary, nil, _time_format, _position), do: summary

  defp append_time(summary, %Time{} = time, time_format, :from) do
    dgettext("dashboard_availability_time_off", "%{range}, from %{time}",
      range: summary,
      time: TimeFormat.format(time, time_format)
    )
  end

  defp append_time(summary, %Time{} = time, time_format, :until) do
    dgettext("dashboard_availability_time_off", "%{range}, until %{time}",
      range: summary,
      time: TimeFormat.format(time, time_format)
    )
  end
end

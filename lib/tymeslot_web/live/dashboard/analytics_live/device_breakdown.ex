defmodule TymeslotWeb.Dashboard.AnalyticsLive.DeviceBreakdown do
  @moduledoc """
  Renders the device-type split (mobile / desktop / tablet / …) for the
  analytics window as a labelled bar per device. The `devices` list comes from
  `Tymeslot.Analytics.device_breakdown/3`.
  """
  use TymeslotWeb, :html

  attr :devices, :list, required: true

  @spec breakdown(map()) :: Phoenix.LiveView.Rendered.t()
  def breakdown(assigns) do
    total = Enum.reduce(assigns.devices, 0, &(&1.visits + &2))

    rows =
      Enum.map(assigns.devices, fn %{device_type: type, visits: visits} ->
        %{label: label(type), visits: visits, percent: percent(visits, total)}
      end)

    assigns = assign(assigns, rows: rows)

    ~H"""
    <div class="card-glass">
      <div class="mb-4 text-token-sm font-black uppercase tracking-widest text-tymeslot-400">
        Devices
      </div>
      <div :if={@rows == []} class="text-token-sm text-tymeslot-400">
        No traffic in this period yet.
      </div>
      <div :if={@rows != []} class="space-y-3">
        <div :for={row <- @rows}>
          <div class="mb-1 flex items-center justify-between text-token-sm">
            <span class="font-semibold text-tymeslot-900">{row.label}</span>
            <span class="tabular-nums text-tymeslot-500">
              {row.visits} ({row.percent}%)
            </span>
          </div>
          <div class="h-2 w-full overflow-hidden rounded-token-full bg-tymeslot-100">
            <div class="h-full rounded-token-full bg-turquoise-500" style={"width: #{row.percent}%"}>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp label("mobile"), do: "Mobile"
  defp label("desktop"), do: "Desktop"
  defp label("tablet"), do: "Tablet"
  defp label(_other), do: "Unknown"

  defp percent(_visits, 0), do: "0.0"

  defp percent(visits, total) do
    :erlang.float_to_binary(visits / total * 100, decimals: 1)
  end
end

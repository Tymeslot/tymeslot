defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents do
  @moduledoc """
  Shared UI components for integration configuration pages.
  Reduces code duplication across calendar and video integration configs.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders a close button (red X) in the top-right corner.

  ## Examples

      <.close_button target={@target} />
  """
  attr :target, :any, required: true
  attr :class, :string, default: "absolute top-0 right-0"

  @spec close_button(map()) :: Phoenix.LiveView.Rendered.t()
  def close_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="back_to_providers"
      phx-target={@target}
      class={[
        @class,
        "group flex items-center gap-1 p-2 text-red-500 hover:text-red-700",
        "hover:bg-red-50 rounded-md transition-all duration-200",
        "focus:outline-hidden focus:ring-2 focus:ring-red-500 focus:ring-offset-2"
      ]}
      title={dgettext("dashboard_integrations", "Close")}
    >
      <.icon name="hero-x-mark" class="w-6 h-6" />
      <span class="text-sm font-medium text-red-500 group-hover:text-red-700 transition-colors duration-200">
        {dgettext("dashboard_integrations", "Close")}
      </span>
    </button>
    """
  end

  @doc """
  Renders a form submit button with loading state.

  ## Examples

      <.form_submit_button saving={@saving} />
      <.form_submit_button saving={@saving} text="Save Integration" />
  """
  attr :saving, :boolean, required: true
  attr :text, :string, default: nil
  attr :saving_text, :string, default: nil
  attr :class, :string, default: "btn btn-primary"

  @spec form_submit_button(map()) :: Phoenix.LiveView.Rendered.t()
  def form_submit_button(assigns) do
    ~H"""
    <button type="submit" disabled={@saving} class={@class}>
      <%= if @saving do %>
        <span class="flex items-center">
          <.spinner class="h-4 w-4 mr-2" />
          {@saving_text || dgettext("dashboard_integrations", "Adding...")}
        </span>
      <% else %>
        {@text || dgettext("dashboard_integrations", "Add Integration")}
      <% end %>
    </button>
    """
  end

  @doc """
  Renders a secondary button for cancel/back actions.
  """
  attr :target, :any, required: true
  attr :label, :string, default: nil
  attr :icon, :string, default: nil
  attr :phx_click, :string, default: "back_to_providers"
  attr :class, :string, default: "btn btn-secondary"

  @spec secondary_button(map()) :: Phoenix.LiveView.Rendered.t()
  def secondary_button(assigns) do
    ~H"""
    <button
      type="button"
      class={@class}
      phx-click={@phx_click}
      phx-target={@target}
    >
      <%= if @icon do %>
        <.icon name={@icon} class="w-4 h-4 mr-2" />
      <% end %>
      {@label || dgettext("dashboard_integrations", "Cancel")}
    </button>
    """
  end

  @doc """
  Renders a small amber warning badge indicating connection issues for an integration.

  ## Examples

      <.health_warning_badge />
      <.health_warning_badge class="absolute top-2 right-2 z-10 ..." />
  """
  attr :class, :string,
    default:
      "flex items-center gap-1 text-xs text-amber-600 bg-amber-50 border border-amber-200 rounded-full px-2 py-0.5"

  @spec health_warning_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def health_warning_badge(assigns) do
    ~H"""
    <span class={@class}>
      <.icon name="hero-exclamation-triangle" class="w-3 h-3 shrink-0" />
      {dgettext("dashboard_integrations", "Connection issues")}
    </span>
    """
  end

  @doc """
  Renders a small amber warning badge indicating a calendar integration has no
  calendars selected, so no events will be synced.

  ## Examples

      <.no_calendars_badge />
  """
  attr :class, :string,
    default:
      "flex items-center gap-1 text-xs text-amber-600 bg-amber-50 border border-amber-200 rounded-full px-2 py-0.5"

  @spec no_calendars_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def no_calendars_badge(assigns) do
    ~H"""
    <span
      class={@class}
      title={
        dgettext(
          "dashboard_integrations",
          "No calendars selected - nothing will sync until you pick at least one."
        )
      }
    >
      <.icon name="hero-calendar-mini" class="w-3 h-3 shrink-0" />
      {dgettext("dashboard_integrations", "No calendars selected")}
    </span>
    """
  end

  @doc """
  Renders a small status pill with a coloured dot and label, driven by a
  `:variant`. Colours mirror the shared `info_box` variant map and the amber
  `health_warning_badge` so status indicators stay visually consistent across
  the integrations UI.

  ## Examples

      <.status_badge variant={:ok} label="Healthy" />
      <.status_badge variant={:paused} label="Paused" />
  """
  attr :variant, :atom, required: true, values: [:ok, :warning, :error, :paused, :info]
  attr :label, :string, required: true
  attr :class, :string, default: nil

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-token-full px-2.5 py-1 text-token-xs font-semibold",
      variant_classes(@variant),
      @class
    ]}>
      <span class={["h-1.5 w-1.5 rounded-token-full", dot_classes(@variant)]} aria-hidden="true" />
      {@label}
    </span>
    """
  end

  defp variant_classes(:ok), do: "bg-emerald-50 border border-emerald-200 text-emerald-800"
  defp variant_classes(:warning), do: "bg-amber-50 border border-amber-200 text-amber-800"
  defp variant_classes(:error), do: "bg-red-50 border border-red-200 text-red-800"
  defp variant_classes(:info), do: "bg-sky-50 border border-sky-200 text-sky-800"
  defp variant_classes(:paused), do: "bg-tymeslot-50 border border-tymeslot-200 text-tymeslot-800"

  @doc """
  Maps a status variant to its coloured-dot background class. Shared by
  `status_badge/1` and `TabNav.integrations_tab_nav/1` so the two status
  indicators never drift out of sync.
  """
  @spec dot_classes(atom()) :: String.t()
  def dot_classes(:ok), do: "bg-emerald-500"
  def dot_classes(:warning), do: "bg-amber-500"
  def dot_classes(:error), do: "bg-red-500"
  def dot_classes(:info), do: "bg-sky-500"
  def dot_classes(:paused), do: "bg-tymeslot-400"
end

defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow do
  @moduledoc """
  Unified, status-first connection row shared by the calendar and video
  integration hubs.

  Renders a `card-glass` shell with the provider icon, title (plus optional
  type tag), a one-line summary, a status badge, an optional `:header_action`
  slot (always visible in the collapsed header — used to surface a Reconnect
  control for integrations needing attention), a `StatusSwitch`, and — when a
  `:detail` slot is provided — an expand chevron. Collapse/expand state is owned
  by the caller via the `expanded?` attribute; the row is stateless and emits
  `toggle_event`/`expand_event` back to `@myself`.
  """
  use TymeslotWeb, :html

  import TymeslotWeb.Components.Icons.ProviderIcon
  import TymeslotWeb.Components.UI.StatusSwitch

  import TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents,
    only: [status_badge: 1]

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :icon_type, :atom, default: nil
  attr :title, :string, required: true
  attr :type_tag, :string, default: nil
  attr :summary, :string, required: true
  attr :status, :any, required: true
  attr :active?, :boolean, required: true
  attr :expanded?, :boolean, default: false
  attr :toggle_event, :string, required: true
  attr :expand_event, :string, default: "toggle_row"
  attr :myself, :any, required: true
  slot :header_action
  slot :detail
  slot :actions

  @spec connection_row(map()) :: Phoenix.LiveView.Rendered.t()
  def connection_row(assigns) do
    {variant, label} = assigns.status

    assigns =
      assigns
      |> assign(:variant, variant)
      |> assign(:status_label, label)
      |> assign(:icon_type, icon_type_string(assigns.icon_type))

    ~H"""
    <div class={["card-glass", !@active? && "opacity-70"]}>
      <div class="flex items-center gap-4 p-4">
        <.provider_icon provider={@icon} type={@icon_type} size="medium" class="shrink-0" />
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h3 class="text-token-base font-semibold text-tymeslot-800 truncate">{@title}</h3>
            <span
              :if={@type_tag}
              class="rounded-token-sm bg-tymeslot-100 px-1.5 py-0.5 text-token-xs font-semibold uppercase text-tymeslot-500"
            >
              {@type_tag}
            </span>
          </div>
          <p class="mt-0.5 truncate text-token-sm text-tymeslot-500">{@summary}</p>
        </div>
        <.status_badge variant={@variant} label={@status_label} />
        <div :if={@header_action != []} class="shrink-0">
          {render_slot(@header_action)}
        </div>
        <.status_switch
          id={"toggle-#{@id}"}
          checked={@active?}
          size={:large}
          on_change={@toggle_event}
          target={@myself}
          phx_value_id={@id}
        />
        <button
          :if={@detail != []}
          type="button"
          phx-click={@expand_event}
          phx-value-id={@id}
          phx-target={@myself}
          aria-expanded={to_string(@expanded?)}
          class="p-1 text-tymeslot-400 hover:text-tymeslot-600 transition-colors"
        >
          <.icon name={(@expanded? && "hero-chevron-up") || "hero-chevron-down"} class="h-5 w-5" />
        </button>
      </div>

      <div
        :if={@expanded? and @detail != []}
        class="border-t border-tymeslot-100 bg-tymeslot-50/50 p-4"
      >
        {render_slot(@detail)}
        <div :if={@actions != []} class="mt-4 flex gap-2 border-t border-tymeslot-100 pt-3">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  # `provider_icon/1` takes the provider category as a string ("calendar" |
  # "video" | "oauth" | nil); the row exposes it as the friendlier atom.
  defp icon_type_string(nil), do: nil
  defp icon_type_string(type) when is_atom(type), do: Atom.to_string(type)
end

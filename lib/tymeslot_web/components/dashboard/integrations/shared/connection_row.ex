defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow do
  @moduledoc """
  Unified, status-first connection row shared by the calendar and video
  integration hubs.

  Renders a `card-glass` shell with the provider icon, title (plus optional
  type tag), a one-line summary, a status badge, a `StatusSwitch`, and an
  always-visible `:actions` cluster (reconnect, test, edit, delete, …). The row
  is flat — there is no expand/collapse; every action is reachable in one click.
  On narrow viewports the action cluster wraps onto its own line below the
  identity block. The row is stateless; actions emit events back to `@myself`.
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
  attr :toggle_event, :string, required: true
  attr :myself, :any, required: true
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
    <div class={["card-glass p-4", !@active? && "opacity-70"]}>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:gap-4">
        <div class="flex min-w-0 flex-1 items-center gap-4">
          <.provider_icon provider={@icon} type={@icon_type} size="medium" class="shrink-0" />
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <h3 class="truncate text-token-base font-semibold text-tymeslot-800">{@title}</h3>
              <span
                :if={@type_tag}
                class="rounded-token-sm bg-tymeslot-100 px-1.5 py-0.5 text-token-xs font-semibold uppercase text-tymeslot-500"
              >
                {@type_tag}
              </span>
            </div>
            <p class="mt-0.5 truncate text-token-sm text-tymeslot-500">{@summary}</p>
          </div>
          <.status_badge variant={@variant} label={@status_label} class="shrink-0" />
        </div>

        <div class="flex flex-wrap items-center gap-2 sm:justify-end">
          <.status_switch
            id={"toggle-#{@id}"}
            checked={@active?}
            size={:large}
            on_change={@toggle_event}
            target={@myself}
            phx_value_id={@id}
          />
          <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
            {render_slot(@actions)}
          </div>
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

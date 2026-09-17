defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.KmeetConfig do
  @moduledoc """
  Connect form for kMeet, Infomaniak's hosted video meetings.

  kMeet always runs on one fixed host, so the organiser only names the
  integration; the host is shown read-only for reference.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.Providers.KmeetProvider

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_values, %{})
     |> assign(:form_errors, %{})
     |> assign(:saving, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form_values, fn -> %{} end)
     |> assign_new(:form_errors, fn -> %{} end)
     |> assign_new(:saving, fn -> false end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="kmeet-video-config-modal" class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="kmeet" type="video" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_integrations", "kMeet")}
          </h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            {dgettext("dashboard_integrations", "Infomaniak's hosted video meetings")}
          </p>
        </div>
      </div>

      <form
        id="kmeet-video-integration-form"
        phx-submit="add_integration"
        phx-change="track_form_change"
        phx-target={@target}
        class="space-y-5"
      >
        <input type="hidden" name="integration[provider]" value="kmeet" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={Map.get(@form_values, "name", dgettext("dashboard_integrations", "My kMeet"))}
            target={@target}
          />

          <.host_field id="kmeet_host" />
        </div>

        <%= if error = SharedForm.form_level_error(@form_errors) do %>
          <SharedForm.error_banner error={error} />
        <% end %>

        <div class="flex justify-between items-center pt-4 border-t border-tymeslot-100">
          <button
            type="button"
            phx-click="back_to_providers"
            phx-target={@target}
            class="btn-secondary"
          >
            {dgettext("dashboard_integrations", "Cancel")}
          </button>
          <UIComponents.form_submit_button saving={@saving} />
        </div>
      </form>
    </div>
    """
  end

  @doc """
  The fixed kMeet host, shown read-only. Shared with the edit dialog so both
  explain the locked address in the same words.
  """
  attr :id, :string, required: true

  @spec host_field(map()) :: Phoenix.LiveView.Rendered.t()
  def host_field(assigns) do
    assigns = assign(assigns, :host, KmeetProvider.host())

    ~H"""
    <SharedForm.locked_host_field
      id={@id}
      value={@host}
      tooltip={
        dgettext(
          "dashboard_integrations",
          "kMeet is Infomaniak's hosted service and always uses this address, which cannot be changed."
        )
      }
      helper_text={
        dgettext(
          "dashboard_integrations",
          "Every booking gets its own room, generated automatically."
        )
      }
    />
    """
  end
end

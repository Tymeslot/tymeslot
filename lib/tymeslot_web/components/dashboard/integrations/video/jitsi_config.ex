defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.JitsiConfig do
  @moduledoc """
  Connect form for a Jitsi Meet server the organiser runs or chooses.

  The organiser supplies the server URL and, when the server requires token
  authentication, an App ID and App secret. The provider validates the pair
  when the integration is saved; this form only collects it.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

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
    <div id="jitsi-video-config-modal" class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="jitsi" type="video" size="large" />
        <div>
          <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_integrations", "Jitsi Meet")}
          </h3>
          <p class="text-token-sm text-tymeslot-500 font-medium">
            {dgettext("dashboard_integrations", "Your own Jitsi Meet server")}
          </p>
        </div>
      </div>

      <form
        id="jitsi-video-integration-form"
        phx-submit="add_integration"
        phx-change="track_form_change"
        phx-target={@target}
        class="space-y-5"
      >
        <input type="hidden" name="integration[provider]" value="jitsi" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={Map.get(@form_values, "name", dgettext("dashboard_integrations", "My Jitsi"))}
            target={@target}
          />

          <.server_url_field
            id="jitsi_base_url"
            value={Map.get(@form_values, "base_url", "")}
            form_errors={@form_errors}
            target={@target}
          />

          <.credential_fields
            id_prefix="jitsi"
            form_values={@form_values}
            form_errors={@form_errors}
          />
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
  The Jitsi server URL input. Shared with the edit dialog so both explain the
  public server's sign-in requirement in the same words.

  It is not validated on blur: the generic server URL check words its error
  for another provider, and the Jitsi provider's own check runs on save.
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :form_errors, :map, required: true
  attr :target, :any, required: true

  @spec server_url_field(map()) :: Phoenix.LiveView.Rendered.t()
  def server_url_field(assigns) do
    ~H"""
    <SharedForm.url_field
      id={@id}
      name="integration[base_url]"
      label={dgettext("dashboard_integrations", "Server URL")}
      value={@value}
      placeholder={dgettext("dashboard_integrations", "https://meet.example.com")}
      form_errors={@form_errors}
      error_key={:base_url}
      target={@target}
      validate_on_blur={false}
      helper_text={
        dgettext(
          "dashboard_integrations",
          "The address of your Jitsi server. The public meet.jit.si requires whoever hosts the meeting to sign in before it starts, so a server you run works better for scheduled bookings."
        )
      }
    />
    """
  end

  @doc """
  The optional App ID and App secret, shared by the connect form and the edit
  dialog.

  The secret is never rendered back into the page. With `stored_credentials`
  set (the edit dialog for an integration that already has them), a blank
  secret keeps the stored one, and a checkbox removes both instead; while it
  is ticked the credential inputs are disabled, so they are not submitted.
  """
  attr :id_prefix, :string, required: true
  attr :form_values, :map, required: true
  attr :form_errors, :map, required: true
  attr :stored_credentials, :boolean, default: false

  attr :stored_client_id, :string,
    default: "",
    doc: "shown until the organiser edits the App ID; a disabled input is not submitted"

  @spec credential_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def credential_fields(assigns) do
    assigns =
      assign(
        assigns,
        :removing,
        assigns.stored_credentials and
          Map.get(assigns.form_values, "remove_token_authentication") == "true"
      )

    ~H"""
    <SharedForm.credential_input
      id={"#{@id_prefix}_client_id"}
      name="integration[client_id]"
      type="text"
      icon="hero-identification"
      label={dgettext("dashboard_integrations", "App ID (optional)")}
      value={Map.get(@form_values, "client_id", @stored_client_id)}
      describedby={"#{@id_prefix}_credentials_help"}
      disabled={@removing}
      errors={FormValidationHelpers.field_errors(@form_errors, :client_id)}
    />

    <SharedForm.credential_input
      id={"#{@id_prefix}_client_secret"}
      name="integration[client_secret]"
      type="password"
      icon="hero-key"
      label={dgettext("dashboard_integrations", "App secret (optional)")}
      describedby={
        if @stored_credentials and not @removing,
          do: "#{@id_prefix}_client_secret_keep #{@id_prefix}_credentials_help",
          else: "#{@id_prefix}_credentials_help"
      }
      disabled={@removing}
      errors={FormValidationHelpers.field_errors(@form_errors, :client_secret)}
    >
      <p
        :if={@stored_credentials and not @removing}
        id={"#{@id_prefix}_client_secret_keep"}
        class="mt-2 text-token-xs text-tymeslot-500"
      >
        {dgettext("dashboard_integrations", "Leave blank to keep the current secret.")}
      </p>
    </SharedForm.credential_input>

    <p
      id={"#{@id_prefix}_credentials_help"}
      class="md:col-span-2 -mt-1 text-token-xs text-tymeslot-500"
    >
      {dgettext(
        "dashboard_integrations",
        "Set both if your server requires token authentication; the secret must be at least 32 characters. Each person then gets a link to this meeting's room only, and only yours is marked as moderator. Jitsi honours that marking only when the server has the token_affiliation module enabled and automatic moderator assignment switched off; otherwise a standard install makes whoever joins first the moderator, and a Docker install makes everyone with a link a moderator. Leave both blank for a server that lets anyone in."
      )}
    </p>

    <label
      :if={@stored_credentials}
      for={"#{@id_prefix}_remove_token_authentication"}
      class="md:col-span-2 flex items-start gap-3 p-4 rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 cursor-pointer transition-colors"
    >
      <.input
        type="checkbox"
        id={"#{@id_prefix}_remove_token_authentication"}
        name="integration[remove_token_authentication]"
        value={Map.get(@form_values, "remove_token_authentication", "false")}
      />
      <div class="flex-1">
        <div class="font-bold text-tymeslot-900">
          {dgettext("dashboard_integrations", "Remove token authentication")}
        </div>
        <div class="text-token-sm text-tymeslot-600 font-medium">
          {dgettext(
            "dashboard_integrations",
            "Deletes the stored App ID and App secret. Links then open the room without a token, which only works on a server that lets anyone in."
          )}
        </div>
      </div>
    </label>
    """
  end
end

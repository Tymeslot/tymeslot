defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.NextcloudTalkConfig do
  @moduledoc """
  Connect form for a Nextcloud Talk video integration: the server, a login name
  and an app password, with an offer to copy the server and login from a
  Nextcloud calendar connection the user already holds.

  A copied app password never reaches this form. It stays in the calendar
  integration and is read again when the form is submitted, and only while the
  server and login name still match the copied ones, so it can never be sent
  to another server.

  `server_url_field/1` and `credential_fields/1` are shared with the edit
  dialog, as `JitsiConfig`'s are, so both explain the fields in the same words.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Dashboard.VideoSettings.FormInput
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       form_values: %{},
       form_errors: %{},
       saving: false,
       nextcloud_calendars: [],
       copied_login: nil
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign(
       socket,
       :copying,
       FormInput.copied_login_applies?(socket.assigns.copied_login, socket.assigns.form_values)
     )}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="nextcloud-talk-video-config-modal" class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="nextcloud_talk" type="video" size="large" />
        <div>
          <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_integrations", "Nextcloud Talk")}
          </h3>
          <p class="text-token-sm text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_integrations",
              "A Talk conversation on your own Nextcloud for every booking"
            )}
          </p>
        </div>
      </div>

      <div
        :if={@nextcloud_calendars != []}
        class="p-4 space-y-3 rounded-token-xl border-2 border-tymeslot-100"
      >
        <div>
          <p id="nextcloud_talk_copy_heading" class="text-token-sm font-bold text-tymeslot-900">
            {dgettext("dashboard_integrations", "Use your Nextcloud calendar connection")}
          </p>
          <p id="nextcloud_talk_copy_help" class="mt-1 text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_integrations",
              "Fills in the server and login name, and uses the same app password unless you enter a different one."
            )}
          </p>
        </div>
        <div
          role="group"
          aria-labelledby="nextcloud_talk_copy_heading"
          aria-describedby="nextcloud_talk_copy_help"
          class="flex flex-wrap gap-2"
        >
          <button
            :for={calendar <- @nextcloud_calendars}
            type="button"
            phx-click="copy_nextcloud_login"
            phx-value-id={calendar.id}
            phx-target={@target}
            class="btn-secondary"
          >
            {dgettext("dashboard_integrations", "Copy from %{name}", name: calendar.name)}
          </button>
        </div>
      </div>

      <form
        id="nextcloud-talk-video-integration-form"
        phx-submit="add_integration"
        phx-change="track_form_change"
        phx-target={@target}
        class="space-y-5"
      >
        <input type="hidden" name="integration[provider]" value="nextcloud_talk" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={
              Map.get(@form_values, "name", dgettext("dashboard_integrations", "My Nextcloud Talk"))
            }
            target={@target}
          />

          <.server_url_field
            id="nextcloud_talk_base_url"
            value={Map.get(@form_values, "base_url", "")}
            form_errors={@form_errors}
            target={@target}
          />

          <.credential_fields
            id_prefix="nextcloud_talk"
            form_values={@form_values}
            form_errors={@form_errors}
            copying={@copying}
          />
        </div>

        <p class="text-token-xs text-tymeslot-500 leading-relaxed">
          {dgettext(
            "dashboard_integrations",
            "Each booking gets its own public Talk conversation, and guests join from its link without a Nextcloud account. To skip the lobby and moderate, sign in to Nextcloud in your browser as this login name first, with your usual password and any second factor; the app password works only for Tymeslot. Anyone else, other Nextcloud users included, waits in the lobby until the meeting starts. A conversation is deleted when its booking is cancelled, and about a week after the meeting ends."
          )}
        </p>

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
  The Nextcloud server URL input, shared with the edit dialog.

  Not validated on blur, as Jitsi's is not: the generic server URL check words
  its error for another provider, and the provider's own check runs on save.
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
      placeholder={dgettext("dashboard_integrations", "https://cloud.example.com")}
      form_errors={@form_errors}
      error_key={:base_url}
      target={@target}
      validate_on_blur={false}
      helper_text={
        dgettext(
          "dashboard_integrations",
          "The address you open Nextcloud at, including any subfolder, such as https://example.com/nextcloud."
        )
      }
    />
    """
  end

  @doc """
  The login name and app password, shared with the edit dialog.

  The app password is never rendered back into the page. With
  `stored_credentials` set (the edit dialog), a blank password keeps the stored
  one; with `copying` set (a login copied from a calendar connection and not
  changed since), a blank password uses that connection's.
  """
  attr :id_prefix, :string, required: true
  attr :form_values, :map, required: true
  attr :form_errors, :map, required: true
  attr :stored_credentials, :boolean, default: false
  attr :copying, :boolean, default: false

  @spec credential_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def credential_fields(assigns) do
    ~H"""
    <SharedForm.credential_input
      id={"#{@id_prefix}_client_id"}
      name="integration[client_id]"
      type="text"
      icon="hero-user"
      label={dgettext("dashboard_integrations", "Login name")}
      value={Map.get(@form_values, "client_id", "")}
      describedby={"#{@id_prefix}_client_id_help"}
      required={not @stored_credentials}
      errors={FormValidationHelpers.field_errors(@form_errors, :client_id)}
    >
      <p id={"#{@id_prefix}_client_id_help"} class="mt-2 text-token-xs text-tymeslot-500">
        {dgettext("dashboard_integrations", "The name you sign in to Nextcloud with.")}
      </p>
    </SharedForm.credential_input>

    <SharedForm.credential_input
      id={"#{@id_prefix}_client_secret"}
      name="integration[client_secret]"
      type="password"
      icon="hero-key"
      label={dgettext("dashboard_integrations", "App password")}
      describedby={"#{@id_prefix}_client_secret_help"}
      placeholder="xxxxx-xxxxx-xxxxx-xxxxx-xxxxx"
      required={not (@stored_credentials or @copying)}
      errors={FormValidationHelpers.field_errors(@form_errors, :client_secret)}
    >
      <p id={"#{@id_prefix}_client_secret_help"} class="mt-2 text-token-xs text-tymeslot-500">
        {app_password_help(@stored_credentials, @copying)}
      </p>
    </SharedForm.credential_input>
    """
  end

  defp app_password_help(true, _copying),
    do: dgettext("dashboard_integrations", "Leave blank to keep the current app password.")

  defp app_password_help(false, true),
    do:
      dgettext(
        "dashboard_integrations",
        "Leave blank to use the app password of your calendar connection."
      )

  defp app_password_help(false, false),
    do:
      dgettext(
        "dashboard_integrations",
        "Create one in Nextcloud under Personal settings, Security. Your login password stops working here once two-factor authentication is on."
      )
end

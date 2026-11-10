defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSending.View do
  @moduledoc """
  Renders SMTP identity controls using public settings and credential-free values.

  Credential inputs always render empty. Their parent receives a new DOM id
  after submission so credentials entered in the browser are cleared as well.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailSending.Settings
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.ErrorMessages

  @doc "Renders the owner's SMTP form, delivery state and lifecycle actions."
  @spec settings(map()) :: Phoenix.LiveView.Rendered.t()
  def settings(assigns) do
    assigns =
      assigns
      |> assign(:state, state(assigns))
      |> assign(:verified, match?(%UserSchema{verified_at: %DateTime{}}, assigns.current_user))

    ~H"""
    <div id="email-sending-settings">
      <.card
        :if={@visible}
        title={dgettext("dashboard_email_sending", "Email sending")}
        title_id="email-sending-heading"
      >
        <div class="space-y-6">
          <p class="text-sm text-tymeslot-600">
            {dgettext(
              "dashboard_email_sending",
              "Your SMTP identity sends booking confirmations, reminders, cancellations, rescheduling, approvals, and guest/group notices. Account and security emails use the platform sender."
            )}
          </p>
          <p class="text-sm text-tymeslot-600">
            {dgettext(
              "dashboard_email_sending",
              "Poll emails, dashboard calendar invitations, updates and cancellations, and booking refund notices also use your SMTP identity. Integration health, dispute and payout notices use the platform sender."
            )}
          </p>

          <div
            id="smtp-status"
            data-state={@state}
            role="status"
            aria-live="polite"
            class="rounded-xl bg-tymeslot-50 p-4 space-y-2"
          >
            <h3 class="text-base font-semibold text-tymeslot-900">{status_title(@state)}</h3>
            <p class="text-sm text-tymeslot-600">{status_description(@state, @settings)}</p>
            <p :if={@settings} class="text-sm font-medium text-tymeslot-900 break-words">
              {@settings.from_name} &lt;{@settings.from_address}&gt;
            </p>
            <p
              :if={@settings && @settings.enabled && @settings.last_error}
              id="smtp-delivery-error"
              class="text-sm text-red-700"
            >
              {ErrorMessages.message(@settings.last_error)}
            </p>
          </div>

          <p :if={@notice} id="smtp-notice" role="status" class="text-sm font-medium text-emerald-700">
            {@notice}
          </p>
          <p
            :if={@error_message}
            id="smtp-error"
            role="alert"
            class="text-sm font-medium text-red-700"
          >
            {@error_message}
          </p>

          <.form
            for={%{}}
            id="user-smtp-form"
            class="space-y-6"
            phx-change="validate_smtp"
            phx-submit="test_and_save_smtp"
            phx-target={@myself}
            novalidate
            aria-busy={@pending != nil}
          >
            <fieldset
              id={"smtp-fields-#{@form_generation}"}
              disabled={@pending != nil}
              class="space-y-6"
            >
              <legend class="sr-only">{dgettext("dashboard_email_sending", "SMTP settings")}</legend>
              <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
                <.input
                  id="smtp-host"
                  name="smtp[host]"
                  value={@form_values["host"]}
                  label={dgettext("dashboard_email_sending", "SMTP hostname")}
                  errors={Map.get(@form_errors, :host, [])}
                  required
                  autocomplete="off"
                />
                <.input
                  id="smtp-port"
                  name="smtp[port]"
                  type="select"
                  value={@form_values["port"]}
                  options={[{"587", "587"}, {"465", "465"}]}
                  label={dgettext("dashboard_email_sending", "SMTP port")}
                  errors={Map.get(@form_errors, :port, [])}
                  required
                />
                <.input
                  id="smtp-security"
                  name="smtp[security]"
                  type="select"
                  value={@form_values["security"]}
                  options={[
                    {dgettext("dashboard_email_sending", "Required STARTTLS (port 587)"), "starttls"},
                    {dgettext("dashboard_email_sending", "Implicit TLS (port 465)"), "implicit_tls"}
                  ]}
                  label={dgettext("dashboard_email_sending", "TLS mode")}
                  errors={Map.get(@form_errors, :security, [])}
                  required
                />
                <.input
                  id="smtp-username"
                  name="smtp[username]"
                  value=""
                  label={dgettext("dashboard_email_sending", "SMTP username")}
                  errors={Map.get(@form_errors, :username, [])}
                  autocomplete="off"
                  required={!@settings || !@settings.credentials_configured}
                />
                <.input
                  id="smtp-password"
                  name="smtp[password]"
                  type="password"
                  value=""
                  label={dgettext("dashboard_email_sending", "SMTP password or app password")}
                  errors={Map.get(@form_errors, :password, [])}
                  autocomplete="new-password"
                  required={!@settings || !@settings.credentials_configured}
                />
                <.input
                  id="smtp-from-address"
                  name="smtp[from_address]"
                  type="email"
                  value={@form_values["from_address"]}
                  label={dgettext("dashboard_email_sending", "From address")}
                  errors={Map.get(@form_errors, :from_address, [])}
                  required
                  autocomplete="off"
                />
                <.input
                  id="smtp-from-name"
                  name="smtp[from_name]"
                  value={@form_values["from_name"]}
                  label={dgettext("dashboard_email_sending", "From display name")}
                  errors={Map.get(@form_errors, :from_name, [])}
                  required
                  autocomplete="off"
                />
              </div>
              <p :if={@settings && @settings.credentials_configured} class="text-sm text-tymeslot-600">
                {dgettext(
                  "dashboard_email_sending",
                  "Credentials are saved securely. Leave the username and password blank to keep them."
                )}
              </p>
              <p class="text-sm text-tymeslot-600">
                {dgettext(
                  "dashboard_email_sending",
                  "Use a public SMTP server with authenticated TLS. Your provider must authorize the From address and manage SPF, DKIM, and DMARC for its domain."
                )}
              </p>
              <p class="text-sm text-tymeslot-600">
                {dgettext(
                  "dashboard_email_sending",
                  "A test message is sent only to your current verified account email."
                )}
              </p>
              <p :if={!@verified} class="text-sm text-red-700">
                {ErrorMessages.message(:unverified_user)}
              </p>
              <.action_button
                id="smtp-test-save"
                type="submit"
                disabled={@pending != nil || !@verified}
              >
                <%= if @pending do %>
                  {dgettext("dashboard_email_sending", "Testing and saving…")}
                <% else %>
                  {dgettext("dashboard_email_sending", "Test and save")}
                <% end %>
              </.action_button>
            </fieldset>
          </.form>

          <div :if={@settings} class="border-t border-tymeslot-100 pt-6 space-y-4">
            <div class="flex flex-wrap gap-3">
              <.action_button
                :if={!@settings.enabled}
                id="smtp-enable"
                phx-click="enable_smtp"
                phx-target={@myself}
                disabled={@pending != nil || @form_dirty || !@verified || !tested?(@settings)}
              >
                {dgettext("dashboard_email_sending", "Enable tested identity")}
              </.action_button>
              <.action_button
                :if={@settings.enabled}
                id="smtp-use-platform"
                variant={:secondary}
                phx-click="disable_smtp"
                phx-target={@myself}
              >
                {dgettext("dashboard_email_sending", "Use platform sender")}
              </.action_button>
              <.action_button
                id="smtp-delete"
                variant={:danger_soft}
                disabled={@pending != nil}
                phx-click="request_delete_smtp"
                phx-target={@myself}
              >
                {dgettext("dashboard_email_sending", "Delete saved identity")}
              </.action_button>
              <.action_button
                id="smtp-refresh"
                variant={:ghost}
                disabled={@pending != nil}
                phx-click="refresh_smtp"
                phx-target={@myself}
              >
                {dgettext("dashboard_email_sending", "Refresh status")}
              </.action_button>
            </div>
            <div
              :if={@confirm_delete}
              id="smtp-delete-dialog"
              role="group"
              aria-labelledby="smtp-delete-heading"
              class="rounded-xl border border-red-200 p-4 space-y-3"
            >
              <h3 id="smtp-delete-heading" class="font-semibold text-tymeslot-900">
                {dgettext("dashboard_email_sending", "Delete this SMTP identity?")}
              </h3>
              <p class="text-sm text-tymeslot-600">
                {dgettext(
                  "dashboard_email_sending",
                  "This removes the saved credentials. Scheduling emails will use the platform sender."
                )}
              </p>
              <div class="flex flex-wrap gap-3">
                <.action_button
                  id="smtp-delete-confirm"
                  variant={:danger}
                  phx-click="delete_smtp"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_email_sending", "Delete identity and credentials")}
                </.action_button>
                <.action_button
                  id="smtp-delete-cancel"
                  variant={:secondary}
                  phx-click="cancel_delete_smtp"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_email_sending", "Keep identity")}
                </.action_button>
              </div>
            </div>
          </div>
        </div>
      </.card>
    </div>
    """
  end

  defp state(%{pending: %{}}), do: "testing"
  defp state(%{error_message: error}) when is_binary(error), do: "attention"

  defp state(%{settings: %Settings{enabled: true, last_error: error}}) when is_binary(error),
    do: "attention"

  defp state(%{settings: %Settings{enabled: true}}), do: "enabled"
  defp state(%{settings: %Settings{}}), do: "disabled"
  defp state(_assigns), do: "platform"

  defp status_title("testing"), do: dgettext("dashboard_email_sending", "Testing SMTP settings")

  defp status_title("attention"),
    do: dgettext("dashboard_email_sending", "Email settings need attention")

  defp status_title("enabled"), do: dgettext("dashboard_email_sending", "Custom SMTP is enabled")

  defp status_title("disabled"),
    do: dgettext("dashboard_email_sending", "Custom SMTP is disabled")

  defp status_title("platform"), do: dgettext("dashboard_email_sending", "Using platform sender")

  defp status_description("testing", _settings),
    do:
      dgettext(
        "dashboard_email_sending",
        "The server is being tested. Existing email settings stay unchanged if the test fails."
      )

  defp status_description("attention", %Settings{enabled: true}),
    do:
      dgettext(
        "dashboard_email_sending",
        "Custom SMTP remains selected. Failed scheduling emails are retried without switching to the platform sender."
      )

  defp status_description("attention", _settings),
    do:
      dgettext(
        "dashboard_email_sending",
        "Your current sending identity has not changed. Review the error and test again."
      )

  defp status_description("enabled", _settings),
    do: dgettext("dashboard_email_sending", "Scheduling emails use this SMTP identity.")

  defp status_description(_state, _settings),
    do:
      dgettext("dashboard_email_sending", "Scheduling emails currently use the platform sender.")

  defp tested?(%Settings{revision: revision, tested_revision: revision, tested_at: %DateTime{}}),
    do: true

  defp tested?(_settings), do: false
end

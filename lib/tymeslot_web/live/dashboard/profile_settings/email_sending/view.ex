defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSending.View do
  @moduledoc """
  Renders SMTP identity controls using public settings and credential-free values.

  Credential inputs always render empty. The browser preserves their values
  during validation; new input ids after submission or settings reload clear
  those values without retaining credentials in server state.
  SMTP configuration is rendered only while custom sending setup is open.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailSending.Settings
  alias TymeslotWeb.Components.CoreComponents.Forms
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
          <div id="smtp-status" data-state={@state}>
            <.setting_row
              id="use-custom-smtp"
              label={dgettext("dashboard_email_sending", "Use custom sending email")}
              description={status_description(@state, @settings)}
              control={:switch}
              checked={@custom_smtp_open}
              on_change="toggle_custom_smtp"
              target={@myself}
              aria-controls="smtp-custom-settings"
            />
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

          <div :if={@custom_smtp_open} id="smtp-custom-settings" class="space-y-6">
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
              :if={@state != "platform"}
              id="smtp-delivery-status"
              data-state={@state}
              role="status"
              aria-live="polite"
              class="rounded-xl bg-tymeslot-50 p-4 space-y-2"
            >
              <h3 class="text-base font-semibold text-tymeslot-900">{status_title(@state)}</h3>
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

            <p :if={!@settings} class="text-sm text-tymeslot-600">
              {dgettext(
                "dashboard_email_sending",
                "Test and save your SMTP settings to activate this sending identity."
              )}
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
                <legend class="sr-only">
                  {dgettext("dashboard_email_sending", "SMTP settings")}
                </legend>
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
                  <.connection_security_dropdown
                    value={@form_values["security"]}
                    open={@security_dropdown_open && @pending == nil}
                    errors={
                      Enum.uniq(
                        Map.get(@form_errors, :security, []) ++ Map.get(@form_errors, :port, [])
                      )
                    }
                    target={@myself}
                  />
                  <.input
                    id={"smtp-username-#{@form_generation}"}
                    name="smtp[username]"
                    value=""
                    data-smtp-credential
                    label={dgettext("dashboard_email_sending", "SMTP username")}
                    errors={Map.get(@form_errors, :username, [])}
                    autocomplete="off"
                    required={!@settings || !@settings.credentials_configured}
                  />
                  <.input
                    id={"smtp-password-#{@form_generation}"}
                    name="smtp[password]"
                    type="password"
                    value=""
                    data-smtp-credential
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
                <p
                  :if={@settings && @settings.credentials_configured}
                  class="text-sm text-tymeslot-600"
                >
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
                  id="smtp-delete"
                  variant={:danger_soft}
                  disabled={@pending != nil}
                  phx-click="request_delete_smtp"
                  phx-target={@myself}
                >
                  {dgettext("dashboard_email_sending", "Delete saved identity")}
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
        </div>
      </.card>
    </div>
    """
  end

  attr :value, :string, required: true
  attr :open, :boolean, required: true
  attr :errors, :list, required: true
  attr :target, :any, required: true

  # Use the timezone picker's shared shell and styling. Native radio inputs send
  # the complete form through existing validation, with a server-derived port. The
  # hidden input carries the selected value when the popup is absent.
  @spec connection_security_dropdown(map()) :: Phoenix.LiveView.Rendered.t()
  defp connection_security_dropdown(assigns) do
    options = [
      {dgettext("dashboard_email_sending", "Required STARTTLS (port 587)"), "starttls"},
      {dgettext("dashboard_email_sending", "Implicit TLS (port 465)"), "implicit_tls"}
    ]

    selected_label =
      Enum.find_value(options, assigns.value, fn {label, value} ->
        if value == assigns.value, do: label
      end)

    assigns = assign(assigns, options: options, selected_label: selected_label)

    ~H"""
    <div class="form-field-wrapper">
      <label id="smtp-security-label" for="smtp-security-trigger" class="label">
        {dgettext("dashboard_email_sending", "Connection security")}
        <span class="text-red-500 ml-0.5" aria-hidden="true">*</span>
      </label>
      <input :if={!@open} id="smtp-security" name="smtp[security]" type="hidden" value={@value} />
      <.dropdown
        id="smtp-security-dropdown"
        open={@open}
        on_toggle="toggle_smtp_security_dropdown"
        on_close="close_smtp_security_dropdown"
        target={@target}
        position={:top_start}
        role="dialog"
        panel_label={dgettext("dashboard_email_sending", "Connection security")}
        aria-labelledby="smtp-security-label smtp-security-value"
        trigger_class="group relative cursor-pointer w-full text-left rounded-token-2xl focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 disabled:cursor-not-allowed disabled:opacity-60"
        trigger_attrs={[
          {"id", "smtp-security-trigger"},
          {"aria-invalid", if(@errors != [], do: "true")},
          {"aria-describedby", if(@errors != [], do: "smtp-security-error")}
        ]}
        class="right-0 brand-card overflow-hidden p-1"
      >
        <:trigger>
          <span class={["input", @errors != [] && "input-error"]}>
            <span class="flex items-center justify-between gap-3">
              <span id="smtp-security-value" class="text-sm font-medium text-tymeslot-800">
                {@selected_label}
              </span>
              <.icon
                name="hero-chevron-down"
                class={[
                  "w-4 h-4 transition-transform duration-200 text-tymeslot-500",
                  @open && "rotate-180"
                ]}
              />
            </span>
          </span>
        </:trigger>
        <:panel>
          <label
            :for={{label, value} <- @options}
            for={"smtp-security-option-#{value}"}
            class={[
              "block w-full text-left px-3 py-2.5 text-sm font-medium text-tymeslot-800 rounded-lg cursor-pointer transition-all duration-200 hover:bg-cyan-50 hover:shadow-sm border hover:border-cyan-200 focus-within:ring-2 focus-within:ring-turquoise-400",
              if(@value == value, do: "bg-cyan-50 border-cyan-200", else: "border-transparent")
            ]}
          >
            <.input
              id={"smtp-security-option-#{value}"}
              type="radio"
              name="smtp[security]"
              value={value}
              checked={@value == value}
              class="sr-only"
              phx-click={@value == value && "close_smtp_security_dropdown"}
              phx-value-selection="true"
              phx-target={@target}
            />
            {label}
          </label>
        </:panel>
      </.dropdown>
      <Forms.field_error errors={@errors} id="smtp-security-error" />
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

  defp status_title("platform"), do: dgettext("dashboard_email_sending", "Email sending")

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
end

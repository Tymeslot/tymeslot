defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.ExchangeConfig do
  @moduledoc """
  Configuration form for connecting a Microsoft Exchange mailbox over EWS.

  Deliberately not built on `ConfigBase` or the shared CalDAV `config_form/1`.
  Exchange is not a CalDAV server, and three differences make the shared form
  the wrong shape rather than merely a loose fit:

    * **A mailbox address is required, and is not the username.** EWS answers
      availability for a mailbox, not a folder, and an on-premises server
      accepts a login (`DOMAIN\\samaccountname`) that is not itself
      addressable. The two are separate inputs.
    * **`verify_ssl` is offered.** An on-premises Exchange behind a
      self-signed or internal-CA certificate is the ordinary case here, not
      the exception, which is why `Exchange.Provider.config_schema/0` declares
      the field while every CalDAV provider hardcodes it true.
    * **Folders are selected by `FolderId`, not by path.** The shared
      `calendar_selection/1` keys its checkboxes on `calendar.path`, which an
      EWS folder does not have.

  The copy carries two behavioural differences the user has to know about.
  Deselecting a calendar narrows what appears on the dashboard grid, but
  **not** the busy time this mailbox contributes: availability comes from
  `GetUserAvailability`, which answers for the whole mailbox and cannot be
  narrowed to a folder. And the mailbox is written to as well as read —
  confirmed bookings go to the calendar chosen as the booking destination —
  while `FindFolder` states no per-folder rights, so a folder the account
  cannot write to looks exactly like one it can until the first booking fails
  (see `Exchange.Creation`).
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"exchange-config-#{@id}"} class="space-y-6">
      <div class="flex items-center gap-4">
        <ProviderIcon.provider_icon provider="exchange" type="calendar" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_calendar_providers", "Microsoft Exchange")}
          </h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_calendar_providers",
              "Sync busy time and bookings with an on-premises Exchange Server"
            )}
          </p>
        </div>
      </div>

      <%= if @show_calendar_selection do %>
        <.selection_step
          id={@id}
          target={@target}
          form_errors={@form_errors}
          form_values={@form_values}
          discovered_calendars={@discovered_calendars}
          discovery_credentials={@discovery_credentials}
          saving={@saving}
        />
      <% else %>
        <.credentials_step
          target={@target}
          form_errors={@form_errors}
          form_values={@form_values}
          saving={@saving}
        />
      <% end %>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :saving, :boolean, required: true

  defp credentials_step(assigns) do
    ~H"""
    <form
      id="exchange-discovery-form"
      phx-submit="discover_calendars"
      phx-change="track_form_change"
      phx-target={@target}
      class="space-y-5"
    >
      <input type="hidden" name="integration[provider]" value="exchange" />

      <p class="text-sm text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_providers",
          "Enter your EWS endpoint and credentials to discover the mailbox's calendars."
        )}
      </p>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <SharedForm.integration_name_field
          form_errors={@form_errors}
          suggested_name={
            Map.get(
              @form_values,
              "name",
              dgettext("dashboard_calendar_providers", "My Exchange")
            )
          }
          placeholder={dgettext("dashboard_calendar_providers", "My Exchange Calendar")}
          target={@target}
        />

        <SharedForm.text_field
          id="exchange_url"
          name="integration[url]"
          label={dgettext("dashboard_calendar_providers", "EWS endpoint URL")}
          value={Map.get(@form_values, "url", "")}
          placeholder="https://mail.example.com/EWS/Exchange.asmx"
          errors={FormValidationHelpers.field_errors(@form_errors, :url)}
          target={@target}
          field="url"
          icon="hero-globe-alt"
        />

        <SharedForm.text_field
          id="exchange_username"
          name="integration[username]"
          label={dgettext("dashboard_calendar_providers", "Username")}
          value={Map.get(@form_values, "username", "")}
          placeholder={dgettext("dashboard_calendar_providers", "name@example.com or DOMAIN\\user")}
          errors={FormValidationHelpers.field_errors(@form_errors, :username)}
          target={@target}
          field="username"
          icon="hero-user"
        />

        <SharedForm.text_field
          id="exchange_password"
          name="integration[password]"
          type="password"
          label={dgettext("dashboard_calendar_providers", "Password")}
          value={Map.get(@form_values, "password", "")}
          placeholder={dgettext("dashboard_calendar_providers", "Password")}
          errors={FormValidationHelpers.field_errors(@form_errors, :password)}
          target={@target}
          field="password"
          icon="hero-lock-closed"
        />

        <SharedForm.text_field
          id="exchange_mailbox"
          name="integration[mailbox]"
          label={dgettext("dashboard_calendar_providers", "Mailbox address")}
          value={Map.get(@form_values, "mailbox", "")}
          placeholder="name@example.com"
          errors={FormValidationHelpers.field_errors(@form_errors, :mailbox)}
          target={@target}
          field="mailbox"
          icon="hero-envelope"
        />
      </div>

      <p class="text-token-sm text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_providers",
          "The mailbox address is the one your busy time is read from. It is often the same as your username, but on a server you sign in to with a domain login it is not."
        )}
      </p>

      <div class="flex items-start gap-3 rounded-token-md bg-tymeslot-50 p-4">
        <.input
          type="checkbox"
          id="exchange_verify_ssl"
          name="integration[verify_ssl]"
          value={Map.get(@form_values, "verify_ssl", "true")}
        />
        <label for="exchange_verify_ssl" class="cursor-pointer">
          <span class="block font-semibold text-tymeslot-800 text-token-sm">
            {dgettext("dashboard_calendar_providers", "Verify the server's TLS certificate")}
          </span>
          <span class="block text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_providers",
              "Leave this on unless your server presents a self-signed certificate. Turning it off means the connection can no longer prove which server it reached."
            )}
          </span>
        </label>
      </div>

      <%!-- Exchange reports no per-folder rights, so a folder the account
            cannot write to is indistinguishable here from one it can. Stating
            that up front is the only warning available before the first
            booking is written; see `Exchange.Creation`. --%>
      <.info_box variant={:info}>
        {dgettext(
          "dashboard_calendar_providers",
          "This mailbox is read from and written to: it blocks the times you're already busy, and confirmed bookings are added to the calendar you choose as your booking destination. Exchange does not report which calendars your account may write to, so if you choose one it cannot write to, the first booking sent there fails."
        )}
      </.info_box>

      <SharedForm.error_banner
        :for={error <- FormValidationHelpers.field_errors(@form_errors, :discovery)}
        error={error}
      />

      <div class="flex justify-between items-center pt-4 border-t border-turquoise-200/30">
        <UIComponents.secondary_button target={@target} />
        <UIComponents.form_submit_button
          saving={@saving}
          text={dgettext("dashboard_calendar_providers", "Discover calendars")}
          saving_text={dgettext("dashboard_calendar_providers", "Discovering...")}
        />
      </div>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :target, :any, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :discovered_calendars, :list, required: true
  attr :discovery_credentials, :map, required: true
  attr :saving, :boolean, required: true

  defp selection_step(assigns) do
    ~H"""
    <form
      id="exchange-integration-form"
      phx-submit="add_integration"
      phx-change="track_form_change"
      phx-target={@target}
      class="space-y-6"
    >
      <SharedForm.integration_name_field
        form_errors={@form_errors}
        suggested_name={
          Map.get(@form_values, "name", dgettext("dashboard_calendar_providers", "My Exchange"))
        }
        placeholder={dgettext("dashboard_calendar_providers", "My Exchange Calendar")}
        target={@target}
      />

      <input type="hidden" name="integration[provider]" value="exchange" />
      <input type="hidden" name="integration[url]" value={@discovery_credentials[:url]} />
      <input type="hidden" name="integration[username]" value={@discovery_credentials[:username]} />
      <input type="hidden" name="integration[password]" value={@discovery_credentials[:password]} />
      <input type="hidden" name="integration[mailbox]" value={Map.get(@form_values, "mailbox", "")} />
      <input
        type="hidden"
        name="integration[verify_ssl]"
        value={Map.get(@form_values, "verify_ssl", "true")}
      />

      <div class="space-y-3">
        <h4 class="label">
          {dgettext("dashboard_calendar_providers", "Select calendars to show on your dashboard:")}
        </h4>

        <div class="brand-card p-4">
          <%= if @discovered_calendars == [] do %>
            <p class="text-sm text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_providers",
                "No calendars were discovered. Double-check your credentials or try again."
              )}
            </p>
          <% else %>
            <div
              :for={calendar <- @discovered_calendars}
              class="flex items-center space-x-3 p-3 rounded-lg hover:bg-white/20 transition-colors"
            >
              <.input
                type="checkbox"
                name="selected_calendars[]"
                value={calendar.id}
                checked
                id={"exchange-calendar-#{@id}-#{checkbox_id(calendar.id)}"}
              />
              <label
                for={"exchange-calendar-#{@id}-#{checkbox_id(calendar.id)}"}
                class="flex-1 cursor-pointer"
              >
                <div class="font-semibold text-tymeslot-800">
                  {calendar.name || dgettext("dashboard_calendar_providers", "Unnamed Calendar")}
                </div>
              </label>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- The one behavioural difference from every other provider, so it is
            stated where the choice is made rather than left to be discovered. --%>
      <.info_box variant={:warning}>
        {dgettext(
          "dashboard_calendar_providers",
          "This choice controls what appears on your dashboard only. Exchange reports busy time for the whole mailbox, so every meeting in it blocks your availability whether or not its calendar is selected here."
        )}
      </.info_box>

      <SharedForm.error_banner
        :for={error <- FormValidationHelpers.field_errors(@form_errors, :discovery)}
        error={error}
      />

      <div class="flex justify-between items-center pt-4 border-t border-turquoise-200/30">
        <UIComponents.secondary_button target={@target} />
        <UIComponents.form_submit_button saving={@saving} />
      </div>
    </form>
    """
  end

  # A `FolderId` is base64 and carries `+`, `/` and `=`, none of which belong
  # in a DOM id. Hashed rather than escaped: the id only has to be stable and
  # unique, and the raw value is already on the checkbox's `value`.
  defp checkbox_id(nil), do: "unknown"

  defp checkbox_id(id) when is_binary(id) do
    :sha256 |> :crypto.hash(id) |> Base.encode16(case: :lower) |> String.slice(0..11)
  end
end

defmodule TymeslotWeb.Dashboard.CalendarSettings.Components do
  @moduledoc """
  Functional components for the calendar settings dashboard.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.{
    CaldavFamilyConfig,
    ExchangeConfig,
    IcsUrlConfig
  }

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.IntegrationCard
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Dashboard.CalendarSettings.CardNotice
  alias TymeslotWeb.Dashboard.CalendarSettings.FeedControls
  alias TymeslotWeb.Dashboard.CalendarSettings.Helpers
  alias TymeslotWeb.Helpers.TimeAgo

  @doc """
  Renders the configuration view for a specific calendar provider.
  """
  attr :selected_provider, :atom, required: true
  attr :myself, :any, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :discovered_calendars, :list, required: true
  attr :show_calendar_selection, :boolean, required: true
  attr :discovery_credentials, :map, required: true
  attr :is_saving, :boolean, required: true

  @spec config_view(map()) :: Phoenix.LiveView.Rendered.t()
  def config_view(assigns) do
    assigns =
      assign(
        assigns,
        :caldav_family?,
        assigns.selected_provider in CaldavFamilyConfig.providers()
      )

    ~H"""
    <div id="calendar-config-view" phx-hook="ScrollReset" data-action={@selected_provider}>
      <%= cond do %>
        <% @caldav_family? -> %>
          <CaldavFamilyConfig.caldav_family_config
            provider={@selected_provider}
            target={@myself}
            form_errors={@form_errors}
            form_values={@form_values}
            discovered_calendars={@discovered_calendars}
            show_calendar_selection={@show_calendar_selection}
            discovery_credentials={@discovery_credentials}
            saving={@is_saving}
          />
        <% @selected_provider == :ics_url -> %>
          <.live_component
            module={IcsUrlConfig}
            id="ics-url-config"
            target={@myself}
            form_errors={@form_errors}
            form_values={@form_values}
            saving={@is_saving}
          />
        <% @selected_provider == :exchange -> %>
          <.live_component
            module={ExchangeConfig}
            id="exchange-config"
            target={@myself}
            form_errors={@form_errors}
            form_values={@form_values}
            discovered_calendars={@discovered_calendars}
            show_calendar_selection={@show_calendar_selection}
            discovery_credentials={@discovery_credentials}
            saving={@is_saving}
          />
        <% true -> %>
          <p class="text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_calendar_settings",
              "Configuration form not available for this provider."
            )}
          </p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the free/busy feed section: the read-only iCalendar link that
  publishes when the user is busy, and the controls to enable, regenerate, or
  disable it.
  """
  attr :enabled, :boolean, required: true
  attr :url, :string, default: nil
  attr :myself, :any, required: true

  @spec freebusy_section(map()) :: Phoenix.LiveView.Rendered.t()
  def freebusy_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        size={:lg}
        level={2}
        icon="hero-link"
        title={dgettext("dashboard_calendar_settings", "Free/busy feed")}
        description={
          dgettext(
            "dashboard_calendar_settings",
            "Share a read-only link that publishes when you're busy (not the event details) as a standard iCalendar feed, so other calendar systems can overlay your availability."
          )
        }
      />

      <.card padding={:sm} class="space-y-3">
        <%= if @enabled do %>
          <code class="block w-full overflow-x-auto rounded-token-md bg-tymeslot-50 px-3 py-2 text-token-sm text-tymeslot-700 select-all">
            {@url}
          </code>
          <div class="flex flex-wrap gap-2">
            <.action_button
              variant={:secondary}
              phx-click="regenerate_freebusy"
              phx-target={@myself}
            >
              {dgettext("dashboard_calendar_settings", "Regenerate link")}
            </.action_button>
            <.action_button variant={:ghost} phx-click="disable_freebusy" phx-target={@myself}>
              {dgettext("dashboard_calendar_settings", "Disable feed")}
            </.action_button>
          </div>
        <% else %>
          <.action_button phx-click="enable_freebusy" phx-target={@myself}>
            {dgettext("dashboard_calendar_settings", "Enable free/busy feed")}
          </.action_button>
        <% end %>
      </.card>
    </section>
    """
  end

  @doc """
  Renders the section for already connected calendars.
  """
  attr :integrations, :list, required: true
  attr :is_refreshing, :boolean, required: true
  attr :myself, :any, required: true
  attr :health_states, :map, default: %{}
  attr :stuck_changes, :map, default: %{}

  @spec connected_calendars_section(map()) :: Phoenix.LiveView.Rendered.t()
  def connected_calendars_section(assigns) do
    # Group integrations by active/inactive
    {active, inactive} = Enum.split_with(assigns.integrations, & &1.is_active)

    assigns =
      assigns
      |> assign(:active_integrations, active)
      |> assign(:inactive_integrations, inactive)

    ~H"""
    <div :if={@integrations != []} class="space-y-12">
      <%!-- Active Calendars Section --%>
      <div :if={@active_integrations != []} class="space-y-6">
        <div class="flex items-center justify-between gap-4 flex-col md:flex-row">
          <div>
            <h2 class="text-token-lg font-semibold text-tymeslot-900 flex items-center gap-3">
              <div class="w-2 h-2 rounded-token-full bg-turquoise-500 animate-pulse"></div>
              {dgettext("dashboard_calendar_settings", "Active for Conflict Checking")}
            </h2>
            <p class="text-tymeslot-500 font-medium mt-1 ml-5">
              {dgettext(
                "dashboard_calendar_settings",
                "We'll check these calendars to prevent double bookings automatically."
              )}
            </p>
          </div>

          <.loading_button
            variant={:secondary}
            icon="hero-arrow-path"
            loading={@is_refreshing}
            loading_text={dgettext("dashboard_calendar_settings", "Refreshing...")}
            class="shrink-0"
            phx-click="refresh_all_calendars"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_settings", "Refresh All")}
          </.loading_button>
        </div>

        <div class="grid grid-cols-1 gap-4">
          <%= for integration <- @active_integrations do %>
            <.calendar_connection_row
              integration={integration}
              myself={@myself}
              health_state={Map.get(@health_states, integration.id)}
              stuck={Map.get(@stuck_changes, integration.id)}
            />
          <% end %>
        </div>
      </div>

      <%!-- Inactive Calendars Section --%>
      <div :if={@inactive_integrations != []} class="space-y-6">
        <div>
          <h2 class="text-token-lg font-semibold text-tymeslot-500 flex items-center gap-3">
            <div class="w-2 h-2 rounded-token-full bg-tymeslot-300"></div>
            {dgettext("dashboard_calendar_settings", "Paused Calendars")}
          </h2>
          <p class="text-tymeslot-400 font-medium mt-1 ml-5">
            {dgettext(
              "dashboard_calendar_settings",
              "These calendars are currently ignored during conflict checking."
            )}
          </p>
        </div>

        <div class="grid grid-cols-1 gap-4">
          <%= for integration <- @inactive_integrations do %>
            <.calendar_connection_row
              integration={integration}
              myself={@myself}
              health_state={Map.get(@health_states, integration.id)}
              stuck={Map.get(@stuck_changes, integration.id)}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a single connected calendar integration as a shared
  `integration_card`: a status-first card with a one-line summary and an
  always-visible action bar: Upgrade (Google scope, when needed), Manage
  calendars (opens the selection modal), Reconnect (promoted when the
  integration needs re-authentication), and a Delete icon. There is no
  expand/collapse; every action is one click away.
  """
  attr :integration, :map, required: true
  attr :myself, :any, required: true
  attr :health_state, :map, default: nil

  attr :stuck, :map,
    default: nil,
    doc: "Its changes the server kept refusing (`Calendar.stuck_changes/1`), if any"

  @spec calendar_connection_row(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_connection_row(assigns) do
    integration = assigns.integration
    provider_name = Helpers.format_provider_name(integration.provider)
    calendar_list = integration.calendar_list || []

    # Two distinct questions: a subscribed feed carries no credentials and
    # exactly one calendar, so it gets neither the reconnect nor the
    # manage-calendars action, and it is also the one provider that is
    # read-only by construction, which is what the badge states.
    subscription? = ProviderConfig.subscription?(integration.provider)
    read_only? = ProviderConfig.read_only?(integration.provider)

    assigns =
      assigns
      |> assign(:calendar_list, calendar_list)
      |> assign(:status, integration_status(integration, assigns.health_state))
      |> assign(:summary, calendar_summary(integration))
      |> assign(:last_synced, last_synced(integration))
      |> assign(:subscription?, subscription?)
      |> assign(:feed, subscription? && List.first(calendar_list))
      |> assign(:read_only?, read_only?)
      |> assign(
        :display_name,
        if(integration.name == provider_name, do: provider_name, else: integration.name)
      )

    ~H"""
    <IntegrationCard.integration_card
      id={to_string(@integration.id)}
      title={@display_name}
      type_tag={if @read_only?, do: dgettext("dashboard_calendar_settings", "Read-only")}
      summary={@summary}
      notice={CardNotice.notice(@integration, @health_state, @stuck)}
      status={@status}
      active={@integration.is_active}
      toggle_event="toggle_integration"
      target={@myself}
    >
      <:icon>
        <ProviderIcon.provider_icon
          provider={@integration.provider}
          type="calendar"
          size="medium"
          alt=""
        />
      </:icon>
      <:last_activity :if={@last_synced}>{@last_synced}</:last_activity>
      <:actions>
        <button
          :if={@integration.provider == "google" && Helpers.needs_scope_upgrade?(@integration)}
          phx-click="upgrade_google_scope"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class={Helpers.tile_class(:warning)}
          title={dgettext("dashboard_calendar_settings", "Upgrade Google Calendar permissions")}
        >
          <.icon name="hero-bolt" class="w-4 h-4" /> {dgettext(
            "dashboard_calendar_settings",
            "Upgrade"
          )}
        </button>
        <%!-- Shown even when no calendars have been discovered yet: the modal
             also carries the name and colour, which apply to any connection.
             Not for a subscription, though: it has exactly one calendar,
             always selected, so the modal would offer a choice that does not
             exist. --%>
        <button
          :if={not @subscription?}
          phx-click="manage_calendars"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class={Helpers.tile_class(:neutral)}
          title={
            dgettext(
              "dashboard_calendar_settings",
              "Rename, recolour, and choose which calendars sync"
            )
          }
          aria-label={dgettext("dashboard_calendar_settings", "Manage calendars")}
        >
          <.icon name="hero-squares-2x2" class="w-4 h-4" /><span>{dgettext(
            "dashboard_calendar_settings",
            "Manage calendars"
          )}</span>
        </button>
        <button
          :if={retry_offered?(@integration, @stuck)}
          phx-click="retry_stuck_changes"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class={Helpers.tile_class(:warning)}
          title={
            dgettext(
              "dashboard_calendar_settings",
              "Send the changes this calendar's server refused to it again"
            )
          }
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> {dgettext(
            "dashboard_calendar_settings",
            "Retry changes"
          )}
        </button>
        <button
          :if={Map.get(@integration, :removed_calendars, []) != []}
          phx-click="dismiss_removed_calendars"
          phx-value-id={@integration.id}
          phx-value-shown={
            @integration |> Map.get(:removed_calendars, []) |> Enum.map(& &1.id) |> Jason.encode!()
          }
          phx-target={@myself}
          class={Helpers.tile_class(:neutral)}
          title={
            dgettext(
              "dashboard_calendar_settings",
              "Dismiss the notice about calendars no longer on the server"
            )
          }
        >
          <.icon name="hero-x-mark" class="w-4 h-4" /> {dgettext(
            "dashboard_calendar_settings",
            "Dismiss"
          )}
        </button>
        <FeedControls.feed_controls
          :if={@subscription?}
          integration={@integration}
          feed={@feed}
          display_name={@display_name}
          myself={@myself}
        />
        <%!-- Reconnecting a subscription means pasting a new feed URL, not
        re-entering credentials, so the CalDAV reconnect modal does not apply.
        A revoked feed is replaced by removing this row and subscribing again. --%>
        <.reconnect_button
          :if={not @subscription?}
          provider={@integration.provider}
          integration_id={@integration.id}
          myself={@myself}
          variant={(@integration.needs_reauth && :attention) || :normal}
        />
      </:actions>
      <:end_actions>
        <.icon_button
          icon="hero-trash"
          variant={:danger}
          label={dgettext("dashboard_calendar_settings", "Delete %{name}", name: @display_name)}
          tooltip={dgettext("dashboard_calendar_settings", "Delete")}
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#delete-calendar-modal"
        />
      </:end_actions>
    </IntegrationCard.integration_card>
    """
  end

  # Always-visible reconnect control: oauth providers re-trigger
  # `connect_provider`, everything else opens the CalDAV reconnect modal.
  # `:attention` is the promoted (amber) style used when the integration needs
  # re-authentication; `:normal` is the subtle default.
  attr :provider, :string, required: true
  attr :integration_id, :any, required: true
  attr :myself, :any, required: true
  attr :variant, :atom, values: [:normal, :attention], required: true

  defp reconnect_button(assigns) do
    assigns =
      assign(assigns,
        class: reconnect_button_class(assigns.variant),
        label_class: reconnect_label_class(assigns.variant)
      )

    ~H"""
    <button
      :if={@provider in ["google", "outlook"]}
      phx-click="connect_provider"
      phx-value-provider={@provider}
      phx-target={@myself}
      class={@class}
      title={dgettext("dashboard_calendar_settings", "Reconnect integration")}
      aria-label={dgettext("dashboard_calendar_settings", "Reconnect integration")}
    >
      <.icon name="hero-arrow-path" class="w-4 h-4" /><span class={@label_class}>{dgettext(
        "dashboard_calendar_settings",
        "Reconnect"
      )}</span>
    </button>
    <button
      :if={@provider not in ["google", "outlook"]}
      phx-click="show_reconnect"
      phx-value-id={@integration_id}
      phx-target="#caldav-reconnect-modal"
      class={@class}
      title={dgettext("dashboard_calendar_settings", "Reconnect integration")}
      aria-label={dgettext("dashboard_calendar_settings", "Reconnect integration")}
    >
      <.icon name="hero-arrow-path" class="w-4 h-4" /><span class={@label_class}>{dgettext(
        "dashboard_calendar_settings",
        "Reconnect"
      )}</span>
    </button>
    """
  end

  # The promoted (:attention) style is the amber warning tile; the subtle
  # (:normal) one is the neutral tile.
  defp reconnect_button_class(:attention), do: Helpers.tile_class(:warning)

  defp reconnect_button_class(:normal),
    do: [Helpers.tile_class(:neutral), "max-sm:h-9 max-sm:w-9 max-sm:px-0 max-sm:py-0"]

  # On a phone the routine Reconnect shrinks to its icon so Manage calendars,
  # Reconnect and Delete share one row; a promoted Reconnect is the action the
  # owner has to take, so it keeps its label there too.
  defp reconnect_label_class(:attention), do: nil
  defp reconnect_label_class(:normal), do: "max-sm:sr-only"

  # Retrying resets the changes for the next sync to send, so it is offered
  # only while syncs run: not while the calendar waits to be reconnected or
  # is paused.
  defp retry_offered?(%{needs_reauth: true}, _stuck), do: false
  defp retry_offered?(%{is_active: false}, _stuck), do: false
  defp retry_offered?(_integration, stuck), do: stuck != nil

  @doc """
  Builds a one-line human summary for a calendar integration: account
  email, conflict-check coverage and booking target, dropping absent segments
  gracefully. When it last synced is the card's last-activity line instead.

  Only the OAuth providers record an account email, so a CalDAV-family row
  names its server instead; without it the line would identify neither the
  account nor the host it belongs to.
  """
  @spec calendar_summary(%{:provider => atom() | String.t() | nil, optional(atom()) => term()}) ::
          String.t()
  def calendar_summary(integration) do
    calendar_list = integration.calendar_list || []

    [
      integration.provider_account_email ||
        ConnectionLabels.server_label(Map.get(integration, :base_url)),
      conflict_segment(integration, calendar_list),
      booking_segment(integration)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Status-first badge mapping. Precedence lives in the canonical
  # `HealthCheck.attention_status/2` classifier; this just maps the atom to
  # the card's status tone/label.
  defp integration_status(integration, health) do
    case HealthCheck.attention_status(integration, health) do
      :paused -> {:neutral, dgettext("dashboard_calendar_settings", "Paused")}
      :needs_reauth -> {:warning, dgettext("dashboard_calendar_settings", "Reconnect")}
      :unhealthy -> {:warning, dgettext("dashboard_calendar_settings", "Connection issues")}
      :ok -> {:success, dgettext("dashboard_calendar_settings", "Healthy")}
    end
  end

  defp conflict_segment(%{is_active: true}, calendar_list) when calendar_list != [] do
    selected = Enum.count(calendar_list, & &1.selected)

    dngettext(
      "dashboard_calendar_settings",
      "checks %{selected} of %{count} calendar for conflicts",
      "checks %{selected} of %{count} calendars for conflicts",
      length(calendar_list),
      selected: selected
    )
  end

  defp conflict_segment(_integration, _calendar_list), do: nil

  # This is a display-only summary, so it only names a booking target once one
  # is set; see `Calendar.booking_target/1`, which follows the calendar bookings
  # are actually written to. A read-only target is a problem the user needs to
  # fix, not an absent one, so it is surfaced rather than dropped.
  defp booking_segment(integration) do
    case Calendar.booking_target(integration) do
      {:ok, calendar} ->
        dgettext("dashboard_calendar_settings", "books into %{calendar}",
          calendar: DisplayHelpers.extract_calendar_display_name(calendar)
        )

      {:read_only, _calendar} ->
        read_only_target_segment(integration)

      :none ->
        if BookingEligibility.bookable?(integration), do: nil, else: feed_segment(integration)
    end
  end

  # Two situations, two sentences, and the provider is what tells them apart.
  # A provider that is read-only by construction gets a plain description: a
  # subscribed feed blocks time and never takes bookings, which is how it has
  # always behaved and is nothing to fix. The
  # warning below says "no longer", which is the right thing to tell someone
  # whose writable calendar has become read-only on the server and whose
  # bookings are now failing; saying it about a feed would report a breakage
  # where nothing has changed and nothing is wrong.
  defp read_only_target_segment(integration) do
    if BookingEligibility.bookable?(integration) do
      dgettext("dashboard_calendar_settings", "booking target can no longer accept bookings")
    else
      feed_segment(integration)
    end
  end

  defp feed_segment(%{all_events_busy: true}),
    do:
      dgettext(
        "dashboard_calendar_settings",
        "read-only, every event blocks time, also those marked free"
      )

  defp feed_segment(_integration),
    do: dgettext("dashboard_calendar_settings", "read-only, blocks time but takes no bookings")

  # The card's last-activity line; nothing for a connection never synced.
  # `last_external_sync_at` is what every sync worker stamps and what the
  # staleness banner reads. Whole sentences rather than "Last synced
  # %{time}" around a relative phrase, so each language words the time as
  # its own sentence needs.
  defp last_synced(%{last_external_sync_at: %DateTime{} = synced_at}) do
    case TimeAgo.since(synced_at) do
      :just_now ->
        dgettext("dashboard_calendar_settings", "Last synced just now")

      {:minutes, count} ->
        dngettext(
          "dashboard_calendar_settings",
          "Last synced %{count} minute ago",
          "Last synced %{count} minutes ago",
          count
        )

      {:hours, count} ->
        dngettext(
          "dashboard_calendar_settings",
          "Last synced %{count} hour ago",
          "Last synced %{count} hours ago",
          count
        )

      {:days, count} ->
        dngettext(
          "dashboard_calendar_settings",
          "Last synced %{count} day ago",
          "Last synced %{count} days ago",
          count
        )
    end
  end

  defp last_synced(_integration), do: nil
end

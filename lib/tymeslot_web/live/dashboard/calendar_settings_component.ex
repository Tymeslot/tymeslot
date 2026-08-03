defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
  @moduledoc """
  LiveComponent for managing calendar integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  require Logger

  alias Tymeslot.FreeBusy
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncIcsCalendarWorker
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavReconnectModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CalendarSelectionModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ProviderPickerModal
  alias TymeslotWeb.Dashboard.CalendarSettings.Components
  alias TymeslotWeb.Dashboard.CalendarSettings.ConfigViewComponent
  alias TymeslotWeb.Helpers.IntegrationProviders
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash

  # Providers whose setup happens in an in-app form rather than an OAuth
  # redirect: the CalDAV family plus feed subscriptions.
  @form_provider_strings ProviderConfig.caldav_based_provider_strings() ++
                           ProviderConfig.subscription_provider_strings()

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:integrations, [])
     |> assign(:selected_provider, nil)
     |> assign(:is_refreshing, false)
     |> assign(:health_states, %{})
     |> assign(:show_picker, false)
     |> assign(:managing_calendar_id, nil)
     |> assign(:available_calendar_providers, Calendar.list_available_providers(:calendar))}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> maybe_load_integrations(assigns)
      |> load_freebusy()
      |> assign_new(:security_metadata, fn -> DashboardHelpers.get_security_metadata(socket) end)

    {:ok, socket}
  end

  # The integrations hub already loads the calendar list and health states
  # for its active tab child (one query per hub render instead of two) and
  # passes them down as the `integrations`/`health_states` props. Reuse them
  # when present; fall back to loading independently otherwise — e.g. when
  # mounted standalone via the `:calendar_integration` dashboard action, or
  # when a `send_update/2` targets us with a partial assign (those always
  # want a fresh reload, matching prior behaviour).
  defp maybe_load_integrations(socket, %{
         integrations: _integrations,
         health_states: _health_states
       }),
       do: socket

  defp maybe_load_integrations(socket, _assigns), do: load_integrations(socket)

  defp load_freebusy(socket) do
    case Profiles.get_or_create_profile(socket.assigns.current_user.id) do
      {:ok, profile} ->
        token = profile.freebusy_token

        socket
        |> assign(:freebusy_profile, profile)
        |> assign(:freebusy_enabled, FreeBusy.feed_enabled?(profile))
        |> assign(:freebusy_url, token && url(~p"/free-busy/#{token}"))

      _error ->
        socket
        |> assign(:freebusy_profile, nil)
        |> assign(:freebusy_enabled, false)
        |> assign(:freebusy_url, nil)
    end
  end

  defp update_freebusy(%{assigns: %{freebusy_profile: %{} = profile}} = socket, fun) do
    case fun.(profile) do
      {:ok, _updated} -> load_freebusy(socket)
      {:error, _changeset} -> socket
    end
  end

  defp update_freebusy(socket, _fun), do: socket

  # --- Event Handlers ---

  @impl Phoenix.LiveComponent
  def handle_event("enable_freebusy", _params, socket) do
    {:noreply, update_freebusy(socket, &FreeBusy.enable_feed/1)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("regenerate_freebusy", _params, socket) do
    {:noreply, update_freebusy(socket, &FreeBusy.regenerate_token/1)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("disable_freebusy", _params, socket) do
    {:noreply, update_freebusy(socket, &FreeBusy.disable_feed/1)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_picker", _params, socket) do
    {:noreply, assign(socket, :show_picker, true)}
  end

  def handle_event("hide_picker", _params, socket) do
    {:noreply, assign(socket, show_picker: false, selected_provider: nil)}
  end

  def handle_event("back_to_grid", _params, socket) do
    {:noreply, assign(socket, :selected_provider, nil)}
  end

  def handle_event("manage_calendars", %{"id" => id}, socket) do
    case parse_int(id) do
      {:ok, int_id} -> {:noreply, assign(socket, :managing_calendar_id, int_id)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("close_manage_calendars", _params, socket) do
    {:noreply, assign(socket, :managing_calendar_id, nil)}
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check_integration_write_rate_limit(user_id),
         {:ok, int_id} <- parse_int(id),
         {:ok, _result} <- Calendar.toggle_integration(int_id, user_id) do
      Flash.info("Calendar status updated")
      send(self(), {:integration_updated, :calendar})
      {:noreply, load_integrations(socket)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :duplicate_account} ->
        Flash.error("Cannot reactivate — another active integration already uses this account")
        {:noreply, socket}

      {:error, reason} ->
        Flash.error("Failed to update status: #{inspect(reason)}")
        {:noreply, socket}

      :error ->
        Flash.error("Invalid calendar ID")
        {:noreply, socket}
    end
  end

  def handle_event("connect_provider", %{"provider" => "google"}, socket) do
    case Calendar.initiate_google_oauth(socket.assigns.current_user.id) do
      {:ok, url} -> send(self(), {:external_redirect, url})
      {:error, msg} -> Flash.error(msg)
    end

    {:noreply, socket}
  end

  def handle_event("connect_provider", %{"provider" => "outlook"}, socket) do
    case Calendar.initiate_outlook_oauth(socket.assigns.current_user.id) do
      {:ok, url} -> send(self(), {:external_redirect, url})
      {:error, msg} -> Flash.error(msg)
    end

    {:noreply, socket}
  end

  def handle_event("connect_provider", %{"provider" => provider}, socket)
      when provider in @form_provider_strings do
    {:noreply,
     assign(socket, selected_provider: String.to_existing_atom(provider), show_picker: true)}
  end

  def handle_event("connect_provider", _params, socket) do
    Flash.error("Unsupported provider")
    {:noreply, socket}
  end

  def handle_event("refresh_all_calendars", _params, socket) do
    if socket.assigns.is_refreshing do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id

      case RateLimiter.check_calendar_refresh_rate_limit(user_id) do
        {:error, :rate_limited, message} ->
          Flash.error(message)
          {:noreply, socket}

        :ok ->
          active = Enum.filter(socket.assigns.integrations, & &1.is_active)

          if active == [] do
            {:noreply, assign(socket, :is_refreshing, false)}
          else
            {:noreply,
             socket
             |> assign(:is_refreshing, true)
             |> start_async(:refresh_calendars, fn ->
               Tymeslot.TaskSupervisor
               |> Task.Supervisor.async_stream_nolink(
                 active,
                 fn integration ->
                   {integration.name, refresh_one(integration)}
                 end,
                 max_concurrency: 5,
                 timeout: 30_000,
                 on_timeout: :kill_task
               )
               |> Enum.to_list()
             end)}
          end
      end
    end
  end

  def handle_event(
        "toggle_calendar_selection",
        %{"integration_id" => id, "calendar_id" => cal_id},
        socket
      ) do
    user_id = socket.assigns.current_user.id

    # Re-fetch the integration by id before updating: the struct in
    # socket assigns can be stale if the row was deleted between mount
    # and this click, and CalendarIntegrationSchema has no
    # optimistic_lock — Repo.update on a stale struct returns
    # {:ok, stale_struct} (0 rows affected, no exception) and the user
    # would see a silent no-op.
    with :ok <- RateLimiter.check_integration_write_rate_limit(user_id),
         {:ok, int_id} <- parse_int(id),
         {:ok, integration} <- Calendar.get_integration(int_id, user_id),
         {:ok, _result} <- Calendar.toggle_calendar_selection(integration, cal_id) do
      {:noreply, load_integrations(socket)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error("This calendar integration is no longer available.")
        {:noreply, load_integrations(socket)}

      _other ->
        Flash.error("Failed to update selection")
        {:noreply, socket}
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    # `Calendar.test_connection/1` routes through `ConnectionProbe`, the
    # single choke point for connection-test rate limiting: every provider,
    # OAuth included, now draws from a real bucket, so no compensating guard
    # belongs here.
    with {:ok, int_id} <- parse_int(id),
         {:ok, integration} <- Calendar.get_integration(int_id, user_id),
         {:ok, message} <- Calendar.test_connection(integration) do
      Flash.info(message)
      {:noreply, socket}
    else
      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, socket}

      {:error, {:rate_limited, _message} = refusal} ->
        Flash.error(IntegrationProviders.connection_test_refusal_message(refusal))
        {:noreply, socket}

      {:error, :unattributable} ->
        Flash.error(IntegrationProviders.connection_test_refusal_message(:unattributable))
        {:noreply, socket}

      {:error, reason} ->
        Flash.error("Connection test failed: #{inspect(reason)}")
        {:noreply, socket}

      :error ->
        Flash.error("Invalid calendar ID")
        {:noreply, socket}
    end
  end

  def handle_event("upgrade_google_scope", %{"id" => id}, socket) do
    with {:ok, int_id} <- parse_int(id),
         {:ok, url} <-
           Calendar.initiate_google_scope_upgrade(socket.assigns.current_user.id, int_id) do
      send(self(), {:external_redirect, url})
      {:noreply, socket}
    else
      {:error, :invalid_provider} ->
        Flash.error("Not a Google Calendar")
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, socket}

      {:error, msg} when is_binary(msg) ->
        Flash.error(msg)
        {:noreply, socket}

      _other ->
        Flash.error("Invalid request")
        {:noreply, socket}
    end
  end

  # --- Async Handlers ---

  @impl Phoenix.LiveComponent
  def handle_async(:refresh_calendars, {:ok, results}, socket) do
    {successes, failed_names} =
      Enum.reduce(results, {0, []}, fn
        {:ok, {_name, {:ok, _result}}}, {s, f} -> {s + 1, f}
        {:ok, {name, _error}}, {s, f} -> {s, [name | f]}
        _other, {s, f} -> {s, ["unknown" | f]}
      end)

    failures = length(failed_names)

    cond do
      failures == 0 ->
        Flash.info("All calendars refreshed successfully")

      successes > 0 ->
        detail = format_refresh_failures(Enum.reverse(failed_names))
        Flash.error("#{successes} refreshed, #{failures} failed: #{detail}")

      true ->
        Flash.error("All calendar refreshes failed.")
    end

    {:noreply, socket |> assign(:is_refreshing, false) |> load_integrations()}
  end

  def handle_async(:refresh_calendars, {:exit, reason}, socket) do
    Logger.error("Calendar refresh task crashed", reason: inspect(reason))
    Flash.error("Refresh process failed unexpectedly.")
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  # --- Private Helpers ---

  # A subscription has no discoverable calendar list to refresh — discovery
  # returns the same synthetic entry every time — so "refresh" means
  # re-fetching the feed instead, through the same worker the scheduled sync
  # sweep uses.
  defp refresh_one(%{provider: provider} = integration) do
    if ProviderConfig.subscription?(provider) do
      %{"calendar_integration_id" => integration.id}
      |> SyncIcsCalendarWorker.new()
      |> Oban.insert()
    else
      Calendar.update_integration_with_discovery(integration)
    end
  end

  defp load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = Calendar.list_integrations(user_id)

    health_states =
      user_id
      |> HealthCheck.list_unhealthy_for_user()
      |> Enum.filter(&(&1.integration_type == "calendar"))
      |> Map.new(fn s -> {s.integration_id, Monitor.from_db_record(s)} end)

    socket
    |> assign(:integrations, integrations)
    |> assign(:health_states, health_states)
  end

  # Builds the grouped provider list for the picker modal: OAuth providers
  # (Google, Outlook) first, then CalDAV presets, then feed subscriptions —
  # no nested reveal. Grouping is by the descriptor's family rather than by
  # its `oauth` boolean: a subscribed feed speaks no CalDAV, so listing it
  # under "CalDAV servers" would describe it as something it isn't.
  defp picker_groups(available, integrations) do
    by_family =
      available
      |> Enum.map(&provider_entry(&1, integrations))
      |> Enum.group_by(& &1.family)

    Enum.reject(
      [
        %{label: nil, providers: Map.get(by_family, :oauth, [])},
        %{label: "CalDAV servers", providers: Map.get(by_family, :caldav, [])},
        %{label: "Calendar subscriptions", providers: Map.get(by_family, :subscription, [])},
        %{label: "Other", providers: Map.get(by_family, :other, [])}
      ],
      &(&1.providers == [])
    )
  end

  defp provider_entry(descriptor, integrations) do
    provider = Atom.to_string(descriptor.type)

    %{
      provider: provider,
      title: descriptor.display_name,
      description: descriptor.description,
      click_event: ProviderConfig.click_event(descriptor.type),
      connected?: Enum.any?(integrations, &(&1.provider == provider)),
      oauth?: descriptor.oauth,
      family: descriptor.family
    }
  end

  defp format_refresh_failures(names) when length(names) <= 3 do
    Enum.join(names, ", ")
  end

  defp format_refresh_failures(names) do
    shown = names |> Enum.take(3) |> Enum.join(", ")
    "#{shown} and #{length(names) - 3} more"
  end

  defp parse_int(id) when is_integer(id), do: {:ok, id}

  defp parse_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _other -> :error
    end
  end

  defp parse_int(_arg), do: :error

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-12 pb-24">
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <.section_header icon="hero-calendar-days" title="Calendar Settings" />
        <button
          phx-click="show_picker"
          phx-target={@myself}
          class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600 shrink-0"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Connect a calendar
        </button>
      </div>

      <div class="space-y-12">
        <div>
          <%= if @integrations == [] do %>
            <div class="card-glass p-10 text-center">
              <div class="mx-auto mb-4 flex h-14 w-14 items-center justify-center rounded-token-2xl bg-turquoise-50 text-turquoise-500">
                <.icon name="hero-calendar-days" class="h-7 w-7" />
              </div>
              <h3 class="text-token-lg font-semibold text-tymeslot-800">
                No calendars connected yet
              </h3>
              <p class="mx-auto mt-1 max-w-md text-token-sm text-tymeslot-500">
                Connect a calendar so Tymeslot can read your availability and stop meetings
                being booked when you're already busy.
              </p>
              <button
                phx-click="show_picker"
                phx-target={@myself}
                class="mt-5 inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Connect a calendar
              </button>
            </div>
          <% else %>
            <Components.connected_calendars_section
              integrations={@integrations}
              is_refreshing={@is_refreshing}
              myself={@myself}
              health_states={@health_states}
            />
          <% end %>
        </div>

        <section class="space-y-4">
          <div class="flex items-center gap-2">
            <.icon name="hero-link" class="w-5 h-5 text-turquoise-500" />
            <h3 class="text-token-base font-semibold text-tymeslot-800">Free/busy feed</h3>
          </div>

          <div class="card-glass p-4 space-y-3">
            <p class="text-token-sm text-tymeslot-500">
              Share a read-only link that publishes when you're busy (not the event
              details) as a standard iCalendar feed, so other calendar systems can
              overlay your availability.
            </p>

            <%= if @freebusy_enabled do %>
              <code class="block w-full overflow-x-auto rounded-token-md bg-tymeslot-50 px-3 py-2 text-token-sm text-tymeslot-700 select-all">
                {@freebusy_url}
              </code>
              <div class="flex flex-wrap gap-2">
                <button
                  type="button"
                  class="btn btn-secondary"
                  phx-click="regenerate_freebusy"
                  phx-target={@myself}
                >
                  Regenerate link
                </button>
                <button
                  type="button"
                  class="btn btn-ghost"
                  phx-click="disable_freebusy"
                  phx-target={@myself}
                >
                  Disable feed
                </button>
              </div>
            <% else %>
              <button
                type="button"
                class="btn btn-primary"
                phx-click="enable_freebusy"
                phx-target={@myself}
              >
                Enable free/busy feed
              </button>
            <% end %>
          </div>
        </section>
      </div>

      <ProviderPickerModal.provider_picker_modal
        id="calendar-provider-picker"
        show={@show_picker}
        title="Connect a calendar"
        subtitle="Sync your availability to prevent double bookings."
        target={@myself}
        on_cancel={JS.push("hide_picker", target: @myself)}
        groups={picker_groups(@available_calendar_providers, @integrations)}
        config_active={@selected_provider != nil}
        back_event="back_to_grid"
      >
        <:config>
          <.live_component
            :if={@selected_provider != nil}
            module={ConfigViewComponent}
            id="calendar-config-view-component"
            selected_provider={@selected_provider}
            current_user={@current_user}
            security_metadata={@security_metadata}
          />
        </:config>
      </ProviderPickerModal.provider_picker_modal>

      <CalendarSelectionModal.calendar_selection_modal
        id="calendar-selection"
        show={@managing_calendar_id != nil}
        integration={Enum.find(@integrations, &(&1.id == @managing_calendar_id))}
        target={@myself}
        on_cancel={JS.push("close_manage_calendars", target: @myself)}
      />

      <.live_component
        module={DeleteIntegrationModal}
        id="delete-calendar-modal"
        integration_type={:calendar}
        current_user={@current_user}
      />

      <.live_component
        module={CaldavReconnectModal}
        id="caldav-reconnect-modal"
        current_user={@current_user}
      />
    </div>
    """
  end
end

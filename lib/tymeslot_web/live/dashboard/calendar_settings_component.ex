defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
  @moduledoc """
  LiveComponent for managing calendar integrations in the dashboard.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.FreeBusy
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncIcsCalendarWorker
  alias TymeslotWeb.Dashboard.CalendarSettings.ComponentView
  alias TymeslotWeb.Helpers.IntegrationProviders
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash

  # Providers whose setup happens in an in-app form rather than an OAuth
  # redirect: the CalDAV family, feed subscriptions, and Exchange.
  @form_provider_strings ProviderConfig.caldav_based_provider_strings() ++
                           ProviderConfig.subscription_provider_strings() ++
                           ProviderConfig.ews_provider_strings()

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
      Flash.info(dgettext("dashboard_calendar_settings", "Calendar status updated"))
      send(self(), {:integration_updated, :calendar})
      {:noreply, load_integrations(socket)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :duplicate_account} ->
        Flash.error(
          dgettext(
            "dashboard_calendar_settings",
            "Cannot reactivate - another active integration already uses this account"
          )
        )

        {:noreply, socket}

      {:error, reason} ->
        Flash.error(
          dgettext("dashboard_calendar_settings", "Failed to update status: %{reason}",
            reason: inspect(reason)
          )
        )

        {:noreply, socket}

      :error ->
        Flash.error(dgettext("dashboard_calendar_settings", "Invalid calendar ID"))
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
    Flash.error(dgettext("dashboard_calendar_settings", "Unsupported provider"))
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
    with_owned_integration(socket, id, :write, fn integration ->
      case Calendar.toggle_calendar_selection(integration, cal_id) do
        {:ok, _result} ->
          {:noreply, load_integrations(socket)}

        _error ->
          Flash.error(dgettext("dashboard_calendar_settings", "Failed to update selection"))
          {:noreply, socket}
      end
    end)
  end

  def handle_event("rename_integration", %{"integration_id" => id, "name" => name}, socket) do
    with_owned_integration(socket, id, :appearance, fn integration ->
      case Calendar.rename_integration(integration, name, socket.assigns.security_metadata) do
        {:ok, _updated} ->
          Flash.info(dgettext("dashboard_calendar_settings", "Calendar renamed"))
          send(self(), {:integration_updated, :calendar})
          {:noreply, load_integrations(socket)}

        {:error, %{name: message}} ->
          Flash.error(message)
          {:noreply, socket}

        {:error, _changeset} ->
          Flash.error(dgettext("dashboard_calendar_settings", "Failed to rename calendar"))
          {:noreply, socket}
      end
    end)
  end

  def handle_event(
        "set_integration_colour",
        %{"integration_id" => id, "colour" => colour},
        socket
      ) do
    colour = palette_key(colour)

    if already_coloured?(socket, id, colour) do
      {:noreply, socket}
    else
      with_owned_integration(socket, id, :appearance, fn integration ->
        case Calendar.update_integration(integration, %{colour: colour}) do
          {:ok, _updated} ->
            send(self(), {:integration_updated, :calendar})
            {:noreply, load_integrations(socket)}

          {:error, _changeset} ->
            Flash.error(dgettext("dashboard_calendar_settings", "Failed to update colour"))
            {:noreply, socket}
        end
      end)
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
        Flash.error(dgettext("dashboard_calendar_settings", "Integration not found"))
        {:noreply, socket}

      {:error, {:rate_limited, _message} = refusal} ->
        Flash.error(IntegrationProviders.connection_test_refusal_message(refusal))
        {:noreply, socket}

      {:error, :unattributable} ->
        Flash.error(IntegrationProviders.connection_test_refusal_message(:unattributable))
        {:noreply, socket}

      {:error, reason} ->
        Flash.error(
          dgettext("dashboard_calendar_settings", "Connection test failed: %{reason}",
            reason: inspect(reason)
          )
        )

        {:noreply, socket}

      :error ->
        Flash.error(dgettext("dashboard_calendar_settings", "Invalid calendar ID"))
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
        Flash.error(dgettext("dashboard_calendar_settings", "Not a Google Calendar"))
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error(dgettext("dashboard_calendar_settings", "Integration not found"))
        {:noreply, socket}

      {:error, msg} when is_binary(msg) ->
        Flash.error(msg)
        {:noreply, socket}

      _other ->
        Flash.error(dgettext("dashboard_calendar_settings", "Invalid request"))
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
        # A result shape we cannot read a calendar name out of; it still has to
        # be named in the "… failed: %{detail}" list, so it gets a placeholder
        # that reads as a name rather than a bare adjective.
        _other, {s, f} -> {s, [dgettext("dashboard_calendar_settings", "unknown calendar") | f]}
      end)

    failures = length(failed_names)

    cond do
      failures == 0 ->
        Flash.info(
          dgettext("dashboard_calendar_settings", "All calendars refreshed successfully")
        )

      successes > 0 ->
        detail = format_refresh_failures(Enum.reverse(failed_names))

        Flash.error(
          dgettext(
            "dashboard_calendar_settings",
            "%{successes} refreshed, %{failures} failed: %{detail}",
            successes: successes,
            failures: failures,
            detail: detail
          )
        )

      true ->
        Flash.error(dgettext("dashboard_calendar_settings", "All calendar refreshes failed."))
    end

    {:noreply, socket |> assign(:is_refreshing, false) |> load_integrations()}
  end

  def handle_async(:refresh_calendars, {:exit, reason}, socket) do
    Logger.error("Calendar refresh task crashed", reason: inspect(reason))
    Flash.error(dgettext("dashboard_calendar_settings", "Refresh process failed unexpectedly."))
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  # --- Private Helpers ---

  # A subscription has no discoverable calendar list to refresh (discovery
  # returns the same synthetic entry every time), so "refresh" means
  # re-fetching the feed instead, through the same worker the scheduled sync
  # sweep uses.
  #
  # This asks about the feed family specifically, not about read-only
  # providers: `ics_url` is the only read-only provider left, and the two
  # questions have different answers for everything else. An Exchange mailbox
  # discovers real folders and has no feed to re-fetch, so it belongs on the
  # discovery path with every other credentialed provider.
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

  defp format_refresh_failures(names) when length(names) <= 3 do
    Enum.join(names, ", ")
  end

  defp format_refresh_failures(names) do
    shown = names |> Enum.take(3) |> Enum.join(", ")
    remaining = length(names) - 3

    dngettext(
      "dashboard_calendar_settings",
      "%{shown} and %{count} more",
      "%{shown} and %{count} more",
      remaining,
      shown: shown,
      count: remaining
    )
  end

  # Every write to one integration goes through here: rate limit, parse the id
  # off the DOM, then re-fetch the row scoped to the current user before
  # handing it to `fun`. Re-fetching is not belt-and-braces — the struct in
  # socket assigns can be stale if the row was deleted between mount and this
  # click, and `CalendarIntegrationSchema` has no `optimistic_lock`, so
  # `Repo.update` on a stale struct returns `{:ok, stale_struct}` (0 rows
  # affected, no exception) and the user sees a silent no-op. Keeping the
  # preamble in one place is also what stops a new action from shipping with
  # the rate limit or the ownership check quietly missing.
  #
  # `bucket` says which budget the write draws on. `:write` is the shared
  # integration budget; `:appearance` is the looser one for changes that only
  # affect how a connection is presented. Naming it at the call site is what
  # keeps the choice a visible decision per action rather than a default.
  defp with_owned_integration(socket, id, bucket, fun) do
    user_id = socket.assigns.current_user.id

    with :ok <- check_write_rate_limit(bucket, user_id),
         {:ok, int_id} <- parse_int(id),
         {:ok, integration} <- Calendar.get_integration(int_id, user_id) do
      fun.(integration)
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error(
          dgettext(
            "dashboard_calendar_settings",
            "This calendar integration is no longer available."
          )
        )

        {:noreply, load_integrations(socket)}

      :error ->
        Flash.error(dgettext("dashboard_calendar_settings", "Invalid calendar ID"))
        {:noreply, socket}
    end
  end

  defp check_write_rate_limit(:write, user_id),
    do: RateLimiter.check_integration_write_rate_limit(user_id)

  defp check_write_rate_limit(:appearance, user_id),
    do: RateLimiter.check_integration_appearance_rate_limit(user_id)

  # Clicking the swatch that is already ringed is what someone does while
  # comparing colours, and it asks for nothing. Answering it from the rendered
  # state costs no query and no budget; that state is what the click was aimed
  # at, and if it has drifted from the row the only write skipped is one that
  # would have set what the swatches already show.
  defp already_coloured?(socket, id, colour) do
    Enum.any?(socket.assigns.integrations, fn integration ->
      to_string(integration.id) == to_string(id) and integration.colour == colour
    end)
  end

  # The swatch picker pushes "default" for its clear pill; everything else is a
  # palette key the changeset validates. Mapping the sentinel here keeps it a
  # detail of the picker rather than something the schema has to know about.
  defp palette_key("default"), do: nil
  defp palette_key(colour), do: colour

  defp parse_int(id) when is_integer(id), do: {:ok, id}

  defp parse_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _other -> :error
    end
  end

  defp parse_int(_arg), do: :error

  @impl Phoenix.LiveComponent
  def render(assigns), do: ComponentView.settings(assigns)
end

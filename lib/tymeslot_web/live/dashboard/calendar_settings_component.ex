defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
  @moduledoc """
  LiveComponent for managing calendar integrations in the dashboard.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.FreeBusy
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Profiles
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
     |> assign(:booking_calendar_ids, %{})
     |> assign(:selected_provider, nil)
     |> assign(:is_refreshing, false)
     |> assign(:health_states, %{})
     |> assign(:stuck_changes, %{})
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
  # passes them down as the `integrations`/`health_states`/`stuck_changes`
  # props. Reuse them
  # when present; fall back to loading independently otherwise — e.g. when
  # mounted standalone via the `:calendar_integration` dashboard action, or
  # when a `send_update/2` targets us with a partial assign (those always
  # want a fresh reload, matching prior behaviour).
  defp maybe_load_integrations(socket, %{
         integrations: _integrations,
         health_states: _health_states,
         stuck_changes: _stuck_changes
       }),
       do: assign_booking_calendars(socket)

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

  def handle_event("toggle_all_events_busy", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, int_id} <- parse_int(id),
         %{} = integration <- Enum.find(socket.assigns.integrations, &(&1.id == int_id)),
         {:ok, updated} <-
           Calendar.set_all_events_busy(user_id, int_id, not integration.all_events_busy) do
      Flash.info(all_events_busy_message(updated.all_events_busy))
      send(self(), {:integration_updated, :calendar})
      {:noreply, load_integrations(socket)}
    else
      {:error, {:rate_limited, message}} ->
        Flash.error(message)
        {:noreply, socket}

      _not_changed ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    with_owned_integration(socket, id, &Calendar.toggle_integration/2, fn
      {:ok, _result} ->
        Flash.info(dgettext("dashboard_calendar_settings", "Calendar status updated"))
        send(self(), {:integration_updated, :calendar})
        {:noreply, load_integrations(socket)}

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
    end)
  end

  def handle_event("connect_provider", %{"provider" => provider}, socket)
      when provider in ["google", "outlook"] do
    case Calendar.initiate_oauth(
           String.to_existing_atom(provider),
           socket.assigns.current_user.id
         ) do
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

      {:noreply,
       socket
       |> assign(:is_refreshing, true)
       |> start_async(
         :refresh_calendars,
         Tasks.with_context(fn -> Calendar.refresh_all_integrations(user_id) end)
       )}
    end
  end

  # The ids are those the card rendered, so a calendar recorded since stays.
  def handle_event("dismiss_removed_calendars", %{"id" => id} = params, socket) do
    shown_ids = shown_ids(params)
    dismiss = &Calendar.dismiss_removed_calendars(&1, &2, shown_ids)

    with_owned_integration(socket, id, dismiss, fn
      {:ok, _cleared} ->
        # The hub's banner lists the same calendars, from the parent's copy.
        send(self(), {:integration_updated, :calendar})
        {:noreply, load_integrations(socket)}
    end)
  end

  def handle_event("retry_stuck_changes", %{"id" => id}, socket) do
    with_owned_integration(socket, id, &Calendar.retry_stuck_changes/2, fn
      {:ok, _retried} ->
        Flash.info(
          dgettext(
            "dashboard_calendar_settings",
            "Sending the changes again. This calendar will update shortly."
          )
        )

        {:noreply, load_integrations(socket)}

      {:error, _reason} ->
        Flash.error(
          dgettext(
            "dashboard_calendar_settings",
            "Could not retry the changes. Please try again."
          )
        )

        {:noreply, socket}
    end)
  end

  @calendar_states %{"off" => :off, "show" => :show, "block" => :block}

  def handle_event(
        "set_calendar_state",
        %{"integration_id" => id, "calendar_id" => cal_id, "state" => state},
        socket
      )
      when is_map_key(@calendar_states, state) do
    with_owned_integration(
      socket,
      id,
      &Calendar.set_calendar_state(&1, &2, cal_id, Map.fetch!(@calendar_states, state)),
      &calendar_choice_result(socket, &1)
    )
  end

  def handle_event(
        "set_calendar_blocking",
        %{"integration_id" => id, "calendar_id" => cal_id, "blocks" => blocks},
        socket
      )
      when blocks in ["true", "false"] do
    with_owned_integration(
      socket,
      id,
      &Calendar.set_calendar_blocking(&1, &2, cal_id, blocks == "true"),
      &calendar_choice_result(socket, &1)
    )
  end

  def handle_event(
        "set_calendar_shown",
        %{"integration_id" => id, "calendar_id" => cal_id, "shown" => shown},
        socket
      )
      when shown in ["true", "false"] do
    with_owned_integration(
      socket,
      id,
      &Calendar.set_calendar_shown(&1, &2, cal_id, shown == "true"),
      &calendar_choice_result(socket, &1)
    )
  end

  def handle_event("rename_integration", %{"integration_id" => id, "name" => name}, socket) do
    metadata = socket.assigns.security_metadata

    with_owned_integration(
      socket,
      id,
      &Calendar.rename_integration(&1, &2, name, metadata),
      fn
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
    )
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
      with_owned_integration(
        socket,
        id,
        &Calendar.set_integration_colour(&1, &2, colour),
        fn
          {:ok, _updated} ->
            send(self(), {:integration_updated, :calendar})
            {:noreply, load_integrations(socket)}

          {:error, _changeset} ->
            Flash.error(dgettext("dashboard_calendar_settings", "Failed to update colour"))
            {:noreply, socket}
        end
      )
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
  def handle_async(:refresh_calendars, {:ok, {:error, {:rate_limited, message}}}, socket) do
    Flash.error(message)
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  def handle_async(:refresh_calendars, {:ok, {:ok, []}}, socket) do
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  def handle_async(:refresh_calendars, {:ok, {:ok, results}}, socket) do
    failed_names = for {name, {:error, _reason}} <- results, do: name
    successes = length(results) - length(failed_names)
    failures = length(failed_names)

    cond do
      failures == 0 ->
        Flash.info(
          dgettext("dashboard_calendar_settings", "All calendars refreshed successfully")
        )

      successes > 0 ->
        detail = format_refresh_failures(failed_names)

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
    Logger.error("Calendar refresh task crashed", reason: LogFormat.reason(reason))
    Flash.error(dgettext("dashboard_calendar_settings", "Refresh process failed unexpectedly."))
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  # --- Private Helpers ---

  defp load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = Calendar.list_integrations(user_id)

    health_states = HealthCheck.health_states_for_user(user_id).calendar

    socket
    |> assign(:integrations, integrations)
    |> assign_booking_calendars()
    |> assign(:health_states, health_states)
    |> load_stuck_changes()
  end

  # The calendars bookings go to, which the Manage calendars modal keeps
  # showing and blocking.
  defp assign_booking_calendars(socket) do
    assign(
      socket,
      :booking_calendar_ids,
      Calendar.booking_calendar_ids_by_integration(
        socket.assigns.current_user.id,
        socket.assigns.integrations
      )
    )
  end

  defp calendar_choice_result(socket, {:ok, _updated}), do: {:noreply, load_integrations(socket)}

  defp calendar_choice_result(socket, {:error, :booking_calendar}) do
    Flash.error(
      dgettext(
        "dashboard_calendar_settings",
        "Your booking calendar always blocks your availability."
      )
    )

    {:noreply, load_integrations(socket)}
  end

  defp calendar_choice_result(socket, _error) do
    Flash.error(dgettext("dashboard_calendar_settings", "Failed to update selection"))
    {:noreply, socket}
  end

  defp load_stuck_changes(socket),
    do: assign(socket, :stuck_changes, Calendar.stuck_changes(socket.assigns.current_user.id))

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

  # Every write to one integration goes through here: parse the id off the
  # DOM, then call the context with the current user and that id. The context
  # charges the budget and loads the row scoped to the user, so a forged or
  # stale id answers `:not_found`; this maps the refusals every such write
  # shares to a flash and hands any other result to `on_result`.
  defp with_owned_integration(socket, id, write, on_result) do
    case parse_int(id) do
      {:ok, int_id} ->
        case write.(socket.assigns.current_user.id, int_id) do
          {:error, {:rate_limited, message}} ->
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

          result ->
            on_result.(result)
        end

      :error ->
        Flash.error(dgettext("dashboard_calendar_settings", "Invalid calendar ID"))
        {:noreply, socket}
    end
  end

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

  # A tampered or missing list dismisses nothing.
  defp shown_ids(%{"shown" => shown}) when is_binary(shown) do
    case Jason.decode(shown) do
      {:ok, ids} when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _invalid -> []
    end
  end

  defp shown_ids(_params), do: []

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

  defp all_events_busy_message(true),
    do: dgettext("dashboard_calendar_settings", "Every event in this calendar now blocks time")

  defp all_events_busy_message(false),
    do:
      dgettext(
        "dashboard_calendar_settings",
        "Events this calendar marks as free no longer block time"
      )
end

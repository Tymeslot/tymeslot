defmodule TymeslotWeb.Dashboard.Calendar.Visibility do
  @moduledoc """
  Shows and hides calendars from the surface's rail and the filter chip.

  Two stores, and both are kept: hiding an account writes
  `hidden_integration_ids` on the calendar preferences; hiding one calendar
  writes its `calendar_appearances` row through
  `Tymeslot.Integrations.Calendar.Appearance`, which checks the account is
  the organiser's. The surface holds the calendar store in
  `manual_hidden_keys`.

  An active calendar set (`Tymeslot.CalendarGrid.CalendarSets`) overlays
  both: while one is active it alone decides what shows, the rail's ticks
  edit its members instead of the stores, and the chip's × (`show_all/1`)
  leaves it. `resolve/1` turns the stores and the set into the
  `hidden_integration_ids` and `hidden_calendar_keys` every reader uses
  (see `Tymeslot.CalendarGrid.EffectiveVisibility`). Every change re-filters
  the window already loaded (no query) and pushes it with a cache reset, so
  events from a hidden calendar cannot linger in the hook.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Assigns the effective hidden accounts and calendar keys from the stores and the active set."
  @spec resolve(socket()) :: socket()
  def resolve(socket) do
    %{
      preferences: preferences,
      manual_hidden_keys: manual_keys,
      integrations: integrations,
      active_set: active_set
    } = socket.assigns

    effective =
      EffectiveVisibility.resolve(
        preferences.hidden_integration_ids,
        manual_keys,
        integrations,
        active_set
      )

    assign(socket,
      hidden_integration_ids: effective.hidden_integration_ids,
      hidden_calendar_keys: effective.hidden_calendar_keys
    )
  end

  @doc "Loads the organiser's sets and the active one, then resolves what is hidden."
  @spec load_sets(socket(), map()) :: socket()
  def load_sets(socket, preferences) do
    sets = CalendarSets.list(socket.assigns.current_user.id)

    socket
    |> assign(calendar_sets: sets, active_set: CalendarSets.active_in(sets, preferences))
    |> resolve()
  end

  @doc "Resolves again, rebuilds the rail and pushes the re-filtered window."
  @spec refresh(socket()) :: socket()
  def refresh(socket), do: socket |> resolve() |> SurfaceData.refresh()

  @doc "Puts a saved set in place of the one on its position, the active set included."
  @spec put_set(socket(), map()) :: socket()
  def put_set(socket, %{position: position} = set) do
    sets = Enum.map(socket.assigns.calendar_sets, &if(&1.position == position, do: set, else: &1))

    active =
      case socket.assigns.active_set do
        %{position: ^position} -> set
        other -> other
      end

    assign(socket, calendar_sets: sets, active_set: active)
  end

  @doc """
  Hides a shown account, or shows a hidden one; with a set active, takes
  it out of the set or puts it in whole. Rate limited on the same
  visibility budget as `toggle_calendar/3`.
  """
  @spec toggle_account(socket(), term()) :: socket()
  def toggle_account(socket, raw_id) do
    with {:ok, integration} <- owned_integration(socket, raw_id),
         :ok <- RateLimiter.check(:calendar_visibility, socket.assigns.current_user.id) do
      toggle_account_in(socket, socket.assigns.active_set, integration)
    else
      :error -> socket
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
    end
  end

  @doc """
  Hides a shown calendar, or shows a hidden one; with a set active, edits
  the set. Rate limited on the loose visibility budget: a view control, not a
  settings change.
  """
  @spec toggle_calendar(socket(), term(), term()) :: socket()
  def toggle_calendar(socket, raw_id, calendar_id)
      when is_binary(calendar_id) and calendar_id != "" do
    with {:ok, integration} <- owned_integration(socket, raw_id),
         # Without a set, a hidden account's calendars cannot be ticked one by
         # one (today's rule); with a set, ticking one adds it to the set.
         false <-
           is_nil(socket.assigns.active_set) and
             integration.id in socket.assigns.hidden_integration_ids,
         :ok <- RateLimiter.check(:calendar_visibility, socket.assigns.current_user.id) do
      toggle_calendar_in(socket, socket.assigns.active_set, integration, calendar_id)
    else
      :error -> socket
      true -> socket
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
    end
  end

  def toggle_calendar(socket, _raw_id, _calendar_id), do: socket

  @doc """
  The filter chip's ×: with a set active it leaves the set; otherwise it
  shows every hidden account and calendar.
  """
  @spec show_all(socket()) :: socket()
  def show_all(socket) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check(:calendar_visibility, user_id),
         {:ok, socket} <- clear(socket, socket.assigns.active_set, user_id) do
      refresh(socket)
    else
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
      _failure -> failed(socket)
    end
  end

  defp clear(socket, %{}, user_id) do
    with {:ok, nil} <- CalendarSets.activate(user_id, 0) do
      {:ok,
       socket
       |> SurfaceData.put_preference(:active_calendar_set_id, nil)
       |> assign(:active_set, nil)}
    end
  end

  defp clear(socket, nil, user_id) do
    with {:ok, _preferences} <- Appearance.show_all(user_id) do
      {:ok,
       socket
       |> SurfaceData.put_preference(:hidden_integration_ids, [])
       |> assign(:manual_hidden_keys, MapSet.new())}
    end
  end

  defp toggle_account_in(socket, %{} = set, integration),
    do: save_members(socket, set, CalendarSets.toggle_account(set.members, integration))

  defp toggle_account_in(socket, nil, %{id: integration_id}) do
    hidden = stored_hidden_accounts(socket)

    new_hidden =
      if integration_id in hidden,
        do: List.delete(hidden, integration_id),
        else: [integration_id | hidden]

    save_hidden_accounts(socket, new_hidden)
  end

  defp toggle_calendar_in(socket, %{} = set, integration, calendar_id),
    do:
      save_members(
        socket,
        set,
        CalendarSets.toggle_calendar(set.members, integration, calendar_id)
      )

  defp toggle_calendar_in(socket, nil, %{id: integration_id}, calendar_id) do
    key = {integration_id, calendar_id}
    keys = socket.assigns.manual_hidden_keys
    hide? = not MapSet.member?(keys, key)
    user_id = socket.assigns.current_user.id

    case Appearance.set_hidden(user_id, integration_id, calendar_id, hide?) do
      {:ok, _appearance} ->
        keys = if hide?, do: MapSet.put(keys, key), else: MapSet.delete(keys, key)
        socket |> assign(:manual_hidden_keys, keys) |> refresh()

      {:error, _reason} ->
        failed(socket)
    end
  end

  defp save_members(socket, set, members) do
    case CalendarSets.put_members(socket.assigns.current_user.id, set.position, members) do
      {:ok, saved} -> socket |> put_set(saved) |> refresh()
      {:error, _reason} -> failed(socket)
    end
  end

  # What is stored, not what this socket last saw: a second tab may have
  # hidden another account since, and a write from stale assigns would undo it.
  defp stored_hidden_accounts(socket) do
    socket.assigns.current_user.id
    |> CalendarGrid.get_or_create_preferences()
    |> Map.fetch!(:hidden_integration_ids)
  end

  defp save_hidden_accounts(socket, hidden) do
    case CalendarGrid.save_preferences(socket.assigns.current_user.id, %{
           hidden_integration_ids: hidden
         }) do
      {:ok, _preferences} ->
        socket
        |> SurfaceData.put_preference(:hidden_integration_ids, hidden)
        |> refresh()

      {:error, _changeset} ->
        failed(socket)
    end
  end

  # Only an account in the organiser's loaded integrations can be toggled; an
  # id forged in the browser is ignored rather than written anywhere.
  defp owned_integration(socket, raw_id) do
    with {id, ""} <- Integer.parse(to_string(raw_id)),
         %{} = integration <- Enum.find(socket.assigns.integrations, &(&1.id == id)) do
      {:ok, integration}
    else
      _other -> :error
    end
  end

  defp failed(socket) do
    Flash.put_flash(
      socket,
      :error,
      dgettext("dashboard_calendar", "Couldn't save that change. Please try again.")
    )
  end
end

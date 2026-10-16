defmodule TymeslotWeb.Dashboard.Calendar.Visibility do
  @moduledoc """
  Shows and hides calendars from the surface's rail and the filter chip.

  Two stores, as in the old grid, and both are kept: hiding an account
  writes `hidden_integration_ids` on the calendar preferences; hiding one
  calendar writes its `calendar_appearances` row through
  `Tymeslot.Integrations.Calendar.Appearance`, which checks the account is
  the organiser's. Every change reloads the window and pushes it with a
  cache reset, so events from a hidden calendar cannot linger in the hook.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Hides a shown account, or shows a hidden one."
  @spec toggle_account(socket(), term()) :: socket()
  def toggle_account(socket, raw_id) do
    case owned_integration(socket, raw_id) do
      {:ok, integration_id} ->
        hidden = socket.assigns.hidden_integration_ids

        new_hidden =
          if integration_id in hidden,
            do: List.delete(hidden, integration_id),
            else: [integration_id | hidden]

        save_hidden_accounts(socket, new_hidden)

      :error ->
        socket
    end
  end

  @doc """
  Hides a shown calendar, or shows a hidden one. Rate limited on the loose
  visibility budget the old grid uses: a view control, not a settings change.
  """
  @spec toggle_calendar(socket(), term(), term()) :: socket()
  def toggle_calendar(socket, raw_id, calendar_id)
      when is_binary(calendar_id) and calendar_id != "" do
    user_id = socket.assigns.current_user.id

    with {:ok, integration_id} <- owned_integration(socket, raw_id),
         key = {integration_id, calendar_id},
         hide? = not MapSet.member?(socket.assigns.hidden_calendar_keys, key),
         :ok <- RateLimiter.check(:calendar_visibility, user_id),
         {:ok, _appearance} <- Appearance.set_hidden(user_id, integration_id, calendar_id, hide?) do
      keys =
        if hide?,
          do: MapSet.put(socket.assigns.hidden_calendar_keys, key),
          else: MapSet.delete(socket.assigns.hidden_calendar_keys, key)

      socket |> assign(hidden_calendar_keys: keys) |> SurfaceData.refresh()
    else
      :error -> socket
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
      {:error, _reason} -> failed(socket)
    end
  end

  def toggle_calendar(socket, _raw_id, _calendar_id), do: socket

  @doc "Shows every hidden account and calendar: the filter chip's ×."
  @spec show_all(socket()) :: socket()
  def show_all(socket) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check(:calendar_visibility, user_id),
         :ok <- unhide_calendars(user_id, socket.assigns.hidden_calendar_keys),
         {:ok, _preferences} <-
           CalendarGrid.save_preferences(user_id, %{hidden_integration_ids: []}) do
      socket
      |> SurfaceData.put_preference(:hidden_integration_ids, [])
      |> assign(hidden_integration_ids: [], hidden_calendar_keys: MapSet.new())
      |> SurfaceData.refresh()
    else
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
      _failure -> failed(socket)
    end
  end

  defp unhide_calendars(user_id, keys) do
    Enum.reduce_while(keys, :ok, fn {integration_id, calendar_id}, :ok ->
      case Appearance.set_hidden(user_id, integration_id, calendar_id, false) do
        {:ok, _appearance} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp save_hidden_accounts(socket, hidden) do
    case CalendarGrid.save_preferences(socket.assigns.current_user.id, %{
           hidden_integration_ids: hidden
         }) do
      {:ok, _preferences} ->
        socket
        |> SurfaceData.put_preference(:hidden_integration_ids, hidden)
        |> assign(hidden_integration_ids: hidden)
        |> SurfaceData.refresh()

      {:error, _changeset} ->
        failed(socket)
    end
  end

  # Only an account in the organiser's loaded integrations can be toggled; an
  # id forged in the browser is ignored rather than written to preferences.
  defp owned_integration(socket, raw_id) do
    with {id, ""} <- Integer.parse(to_string(raw_id)),
         true <- Enum.any?(socket.assigns.integrations, &(&1.id == id)) do
      {:ok, id}
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

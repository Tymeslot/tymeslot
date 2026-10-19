defmodule TymeslotWeb.Dashboard.Calendar.LayerChoices do
  @moduledoc """
  The rail's Layers section and B: switching the bookable-times layer on or
  off and choosing the meeting type it shows. Each choice is rate limited,
  saved to the organiser's calendar preferences (see
  `Tymeslot.CalendarGrid.LayerPreferences`, which refuses a meeting type
  that is not the organiser's own), recorded in the assigns the rail
  draws from, and the layer reloads (see `BookableLayer`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid.LayerPreferences
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.BookableLayer
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  What the rail's Layers section shows: whether the layer is on, the
  meeting type it shows and the types it could show.
  """
  @spec rail(map(), [LayerPreferences.choice()]) :: map()
  def rail(preferences, meeting_types),
    do: %{
      on: preferences.bookable_layer,
      meeting_type: LayerPreferences.meeting_type(preferences, meeting_types),
      meeting_types: meeting_types
    }

  @doc """
  Switches the layer to `on`, the value the switch or B asked for (not a
  flip, so a press the server has not answered yet cannot turn into its
  opposite). A refusal (no meeting type, the rate limit, a failed save, a
  value that is neither a boolean nor `:flip`) pushes the layer as it stands, so a grid
  that already followed the press goes back.
  """
  @spec toggle(socket(), boolean() | :flip | term()) :: socket()
  def toggle(%{assigns: %{bookable_types: []}} = socket, _on), do: resync(socket)

  def toggle(socket, :flip), do: toggle(socket, !socket.assigns.preferences.bookable_layer)

  def toggle(socket, on) when is_boolean(on) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check(:calendar_visibility, user_id),
         {:ok, _preferences} <- LayerPreferences.set_layer(user_id, on) do
      socket |> SurfaceData.put_preference(:bookable_layer, on) |> BookableLayer.load()
    else
      refusal -> socket |> refuse(refusal) |> resync()
    end
  end

  def toggle(socket, _on), do: resync(socket)

  @doc "Shows meeting type `id`; one that is not the organiser's own changes nothing."
  @spec choose_type(socket(), term()) :: socket()
  def choose_type(socket, id) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check(:calendar_visibility, user_id),
         {:ok, choice} <- LayerPreferences.choose_meeting_type(user_id, id) do
      socket
      |> SurfaceData.put_preference(:bookable_meeting_type_id, choice.id)
      |> BookableLayer.load()
    else
      {:error, :not_found} -> socket
      refusal -> refuse(socket, refusal)
    end
  end

  # The layer as last pushed; before the first push the hook has nothing
  # it could have changed.
  defp resync(%{assigns: %{bookable: nil}} = socket), do: socket
  defp resync(socket), do: push_event(socket, "calendar:bookable", socket.assigns.bookable)

  defp refuse(socket, {:error, :rate_limited, message}),
    do: Flash.put_flash(socket, :error, message)

  defp refuse(socket, _error),
    do:
      Flash.put_flash(
        socket,
        :error,
        dgettext("dashboard_calendar_booking", "Couldn't save that change. Please try again.")
      )
end

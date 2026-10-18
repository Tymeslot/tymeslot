defmodule TymeslotWeb.Dashboard.Calendar.Creation do
  @moduledoc """
  Creating events from the calendar surface.

  A checked create (`Tymeslot.CalendarGrid.CreateParams`) is written in a
  supervised task (`Changes.create_event/2`) and held in `pending_creates`,
  keyed by the hook's draft id, until `{:calendar_create_result, draft,
  result}` comes back through `CalendarRouting` (`settled/3`). The provider
  gives the event its identity, so nothing is shown in its place before it
  answers; the draft stays drawn meanwhile.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.WriteTask
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData

  @type socket :: Phoenix.LiveView.Socket.t()

  # What the task answers if the create raises: the draft goes and the
  # organiser is told it failed, rather than "Saving…" staying forever.
  @crashed {:error, %{reason: :crashed, retry: :not_queued}}

  @doc """
  Starts writing `params` for the draft `draft`, within the calendar edit
  rate limit.
  """
  @spec start(socket(), String.t(), CreateParams.t()) ::
          {:ok, socket()} | {:error, :rate_limited, String.t()}
  def start(socket, draft, %CreateParams{} = params) when is_binary(draft) do
    user_id = socket.assigns.current_user.id

    with :ok <- EditGuard.rate_limit(user_id) do
      :ok =
        WriteTask.start(
          {:calendar_create_result, draft},
          fn -> Changes.create_event(user_id, params) end,
          @crashed
        )

      {:ok,
       assign(socket, :pending_creates, Map.put(socket.assigns.pending_creates, draft, params))}
    end
  end

  @doc """
  The create for `draft` has answered: a created event is in the cache, so
  the window reloads; a failed one's draft is dropped in the hook.
  """
  @spec settled(socket(), String.t(), term()) :: socket()
  def settled(socket, draft, result) do
    socket
    |> assign(:pending_creates, Map.delete(socket.assigns.pending_creates, draft))
    |> settle(draft, result)
  end

  defp settle(socket, _draft, {:ok, _created}), do: SurfaceData.reload(socket, :events)

  # A queued CalDAV create is tagged in the cache by the offline queue, so the
  # reload shows it waiting to sync.
  defp settle(socket, draft, {:error, %{retry: :queued}}),
    do:
      socket
      |> push_event("calendar:draft-cleared", %{draft: draft})
      |> SurfaceData.reload(:events)

  defp settle(socket, draft, {:error, _failure}),
    do:
      socket
      |> push_event("calendar:draft-cleared", %{draft: draft})
      |> SurfaceData.push_events(false)
end

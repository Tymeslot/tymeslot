defmodule TymeslotWeb.Dashboard.Polls.SelectedPoll do
  @moduledoc """
  The selected poll's state on `PollsComponent`'s socket: the poll itself,
  its tallies and winning slot, the advisory calendar conflict check, the
  inline errors under its slots, and its PubSub subscription.

  A selected draft opens in the create form instead of the results panel, and
  one another tab has since published or deleted is let go of with a word to
  the host.

  The slot-health check runs off the LiveView process with `start_async/3`
  as `:slot_health`, answered in `PollsComponent.handle_async/3`.

  Nothing here works out the next deadline: `PollsComponent` does that once
  both the selected poll and the list are loaded, since the selected poll
  stands in for its list copy.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Polls
  alias Tymeslot.Polls.SlotHealth
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  @health_timeout 6_000

  @doc """
  Selects `poll_id`, starting it with no slot errors and an empty invite
  field. The caller loads it (`fetch/2`).
  """
  @spec open(Socket.t(), Ecto.UUID.t()) :: Socket.t()
  def open(socket, poll_id) do
    assign(socket,
      selected_poll_id: poll_id,
      slot_errors: %{},
      invite_value: "",
      invite_error: nil
    )
  end

  @doc """
  Loads the selected poll afresh, if there is one. With `refresh_health: true`
  an open poll's calendar conflict check runs again.
  """
  @spec fetch(Socket.t(), keyword()) :: Socket.t()
  def fetch(%{assigns: %{selected_poll_id: nil}} = socket, _opts), do: socket

  def fetch(socket, opts) do
    fetched =
      Polls.get_poll_for_host(socket.assigns.selected_poll_id, socket.assigns.current_user.id)

    socket
    |> let_go_of_taken_draft(fetched)
    |> assign_selected(fetched, opts)
  end

  @doc "The draft the create form holds, or nil."
  @spec draft(map() | nil) :: map() | nil
  def draft(%{status: :draft} = poll), do: poll
  def draft(_poll), do: nil

  @doc "Puts `message` under the slot `slot_id`."
  @spec put_error(Socket.t(), String.t(), String.t()) :: Socket.t()
  def put_error(socket, slot_id, message) do
    assign(socket, :slot_errors, Map.put(socket.assigns.slot_errors, slot_id, message))
  end

  @doc "Lets go of the selected poll, its subscription and its prompts."
  @spec clear(Socket.t()) :: Socket.t()
  def clear(socket) do
    if prev = socket.assigns[:selected_poll_id], do: Polls.unsubscribe(prev)

    socket
    |> ModalHook.hide_modal(:delete)
    |> ModalHook.hide_modal(:cancel)
    |> assign(
      selected_poll_id: nil,
      selected_poll: nil,
      tallies: %{},
      slot_health: %{},
      slot_health_loading: false,
      slot_errors: %{},
      winning_slot_id: nil,
      confirming_slot: nil,
      expanded_slots: MapSet.new(),
      editing_details?: false,
      invite_value: "",
      invite_error: nil
    )
  end

  @doc """
  Subscribes to the newly selected poll, dropping the previous subscription so
  a re-selection never accumulates duplicate PubSub deliveries.
  """
  @spec resubscribe(Socket.t(), Ecto.UUID.t()) :: Socket.t()
  def resubscribe(socket, id) do
    if socket.assigns[:selected_poll_id] == id do
      socket
    else
      if prev = socket.assigns[:selected_poll_id], do: Polls.unsubscribe(prev)
      Polls.subscribe(id)
      socket
    end
  end

  # The form holds a draft that another tab has since published or deleted.
  # Left open, it would fall back to an empty create form without a word, so
  # it closes, with the draft's delete prompt, saying why: a published poll's
  # results take its place, and a deleted one leaves the list, which is
  # reloaded for either.
  defp let_go_of_taken_draft(socket, {:ok, %{status: :draft}}), do: socket

  defp let_go_of_taken_draft(%{assigns: %{selected_poll: %{status: :draft}}} = socket, _fetched) do
    Flash.warning(
      dgettext("dashboard_polls", "This draft has already been published or deleted.")
    )

    socket
    |> ModalHook.hide_modal(:delete)
    |> assign(show_form: false, polls: Polls.list_polls(socket.assigns.current_user.id))
  end

  defp let_go_of_taken_draft(socket, _fetched), do: socket

  defp assign_selected(socket, fetched, opts) do
    case fetched do
      {:ok, %{status: :draft} = draft} ->
        # A draft opens in the create form, which keeps the host's edits:
        # it is loaded once, not refreshed under them.
        assign(socket,
          selected_poll: draft,
          show_form: true,
          meeting_types: Polls.meeting_types_for_poll(socket.assigns.current_user.id)
        )

      {:ok, poll} ->
        socket
        |> assign(:selected_poll, poll)
        |> assign(:unconfirmed_count, Polls.count_unconfirmed(poll))
        |> assign(:tallies, Polls.tallies(poll))
        |> assign(:winning_slot_id, Polls.winning_slot_id(poll))
        |> sync_slot_health(poll, opts)

      {:error, :not_found} ->
        clear(socket)
    end
  end

  # Slot health is meaningful only while voting is open. A confirmed poll's own
  # minted meeting sits on the host calendar, so checking it would flag the
  # winning slot as a conflict against itself; a cancelled poll needs no badges.
  defp sync_slot_health(socket, %{status: :open} = poll, opts) do
    if Keyword.get(opts, :refresh_health, false) do
      request_slot_health(socket, poll)
    else
      socket
    end
  end

  defp sync_slot_health(socket, _poll, _opts) do
    assign(socket, slot_health: %{}, slot_health_loading: false)
  end

  # Runs the advisory calendar conflict check off the LiveView process so a slow
  # provider never freezes the dashboard. The panel renders immediately in a
  # "checking" state; the result names its poll, so it is applied only while
  # that poll is still selected. `SlotHealth.check_within/2` bounds the
  # calendar fetch and degrades to all-`:ok` on timeout or failure.
  defp request_slot_health(socket, poll) do
    socket
    |> assign(slot_health: %{}, slot_health_loading: true)
    |> start_async(
      :slot_health,
      Tasks.with_context(fn -> {poll.id, SlotHealth.check_within(poll, @health_timeout)} end)
    )
  end
end

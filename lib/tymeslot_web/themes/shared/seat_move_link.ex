defmodule TymeslotWeb.Themes.Shared.SeatMoveLink do
  @moduledoc """
  The `reschedule_seat_token` a group participant's "move my spot" link
  opens the booking page with.

  A live token makes the page a seat move: the token is what the submit
  moves, and its seat's start is the time the date step says the spot is
  moving from (`:reschedule_seat_from`).

  The token rides in the URL, which browser history, bookmarks and shared
  links keep long after the seat has been moved or given up. A spent one is
  forgotten, so it cannot route every later submission through a seat move
  that can only fail, and the page is sent on to the host's booking page
  from the start without it, with a word on why: left where it was, the
  visitor would find a picker that silently books afresh.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Tymeslot.Scheduling.ThemeFlow
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @doc """
  Assigns `:reschedule_seat_token` and `:reschedule_seat_from` from the
  token in the URL: both `nil` when there is none or it is spent.
  """
  @spec assign_from_url(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def assign_from_url(socket, requested_token) do
    seat_move_from = ThemeFlow.seat_move_start(requested_token)

    socket
    |> assign(:reschedule_seat_token, if(seat_move_from, do: requested_token))
    |> assign(:reschedule_seat_from, seat_move_from)
  end

  @doc """
  Sends a page whose URL named a spent token on to a fresh booking. Run
  after `assign_from_url/2`; a page with a live token, or none, is left as
  it is.
  """
  @spec leave_if_spent(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def leave_if_spent(%{assigns: %{reschedule_seat_token: nil}} = socket, requested_token)
      when is_binary(requested_token) do
    socket
    |> put_flash(
      :info,
      dgettext(
        "booking",
        "This link to move your spot has already been used. You can book a new time below."
      )
    )
    |> push_navigate(to: PathHandlers.restart_path(socket))
  end

  def leave_if_spent(socket, _requested_token), do: socket
end

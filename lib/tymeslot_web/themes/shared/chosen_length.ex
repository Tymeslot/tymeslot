defmodule TymeslotWeb.Themes.Shared.ChosenLength do
  @moduledoc """
  The length a booking page is working with, for a meeting type that offers
  several (`Tymeslot.MeetingTypes.Lengths`).

  Two assigns carry it. `:chosen_length_minutes` is the booker's pick — from
  the length step, or preselected by `?minutes=` on a direct link.
  `:reschedule_length_minutes` is the length of the booking being moved, which
  a reschedule keeps rather than asking for again. Neither is trusted on its
  own: `Tymeslot.Availability.Offer.duration_minutes/3` resolves either against
  the lengths the type actually offers, and the booking submit does the same.

  Kept out of `LiveHelpers` so the page's param and entry handlers only say
  *when* the length is settled, and this module says how.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes.Lengths
  alias Tymeslot.Scheduling.ThemeFlow

  @doc """
  Takes a length named by `?minutes=` in the URL, when there is one.

  Only parsed here; whether the type offers it is decided where the length is
  used, so a length the type does not offer simply leaves the booker to choose.
  """
  @spec from_params(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def from_params(socket, params) do
    case Lengths.parse(params["minutes"]) do
      minutes when is_integer(minutes) -> assign(socket, :chosen_length_minutes, minutes)
      nil -> socket
    end
  end

  @doc """
  Drops the chosen length when the newly resolved `meeting_type` does not offer
  it: a length picked for one type means nothing for another, and the booker
  then chooses again.
  """
  @spec keep_if_offered(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def keep_if_offered(socket, meeting_type) do
    if Lengths.offers?(meeting_type, socket.assigns[:chosen_length_minutes]),
      do: socket,
      else: assign(socket, :chosen_length_minutes, nil)
  end

  @doc """
  Records the length of the booking a reschedule is moving, once.

  Read from the meeting itself, scoped to the organiser, so the grid a
  reschedule is offered is the one its booking was made on — however the page
  was entered.
  """
  @spec assign_for_reschedule(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_for_reschedule(socket) do
    uid = socket.assigns[:reschedule_meeting_uid]

    if is_binary(uid) and is_nil(socket.assigns[:reschedule_length_minutes]) do
      assign(
        socket,
        :reschedule_length_minutes,
        ThemeFlow.reschedule_length_minutes(uid, socket.assigns[:organizer_user_id])
      )
    else
      socket
    end
  end
end

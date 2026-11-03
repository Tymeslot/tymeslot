defmodule TymeslotWeb.Themes.Shared.ChosenLength do
  @moduledoc """
  The length a booking page is working with, for a meeting type that offers
  several (`Tymeslot.MeetingTypes.Lengths`).

  `:chosen_length_minutes` is the booker's pick — from the length step, or
  preselected by `?minutes=` on a direct link. A reschedule keeps the length
  of the booking it moves rather than asking for it again, read from the
  booking the page loaded (`:reschedule_context`). Neither is trusted on its
  own: `Tymeslot.Availability.Offer.duration_minutes/3` resolves either against
  the lengths the type actually offers, and the booking submit does the same.

  Kept out of the page's param and entry handlers, which only say *when* the
  length is settled; this module says how. The booking journey asks for the
  length through `Journey.Facts.Length`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Availability.Offer
  alias Tymeslot.MeetingTypes.Lengths

  @doc """
  Whether the booker picks a length: the meeting type offers several, and
  this is not a reschedule, which keeps the length that was booked.
  """
  @spec choose?(map()) :: boolean()
  def choose?(assigns),
    do: Lengths.multiple?(assigns[:meeting_type]) and is_nil(assigns[:reschedule_meeting_uid])

  @doc """
  The length the booking is for as far as the page has settled it: the
  booked length on a reschedule, else the booker's pick, else nil. Not checked
  against the meeting type; `Offer.duration_minutes/3` does that.
  """
  @spec minutes(map()) :: pos_integer() | nil
  def minutes(assigns), do: booked_minutes(assigns) || assigns[:chosen_length_minutes]

  defp booked_minutes(%{reschedule_context: %{meeting: %{duration: minutes}}})
       when is_integer(minutes) and minutes > 0,
       do: minutes

  defp booked_minutes(_assigns), do: nil

  @doc """
  The meeting type as booked for the length in `minutes/1`, for code that
  reads a type's length from its `duration_minutes`, such as the calendar
  grids (`CalendarDays`): how long the booking is also decides how late a
  day can still start. `Offer.duration_minutes/3` decides, so a length the
  type does not offer leaves it at its primary one. Nil without a type.
  """
  @spec meeting_type(map()) :: map() | nil
  def meeting_type(%{meeting_type: %{duration_minutes: primary} = meeting_type} = assigns)
      when is_integer(primary),
      do: %{
        meeting_type
        | duration_minutes: Offer.duration_minutes(meeting_type, nil, minutes(assigns))
      }

  def meeting_type(assigns), do: assigns[:meeting_type]

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
end

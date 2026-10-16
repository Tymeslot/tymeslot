defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Length do
  @moduledoc """
  The meeting's length, for a meeting type that offers several
  (`Tymeslot.MeetingTypes.Lengths`): the booker's pick (`select_length`),
  held in `:chosen_length_minutes` (`ChosenLength`).

  Needed only when the type offers more than one length, the booking is not
  a reschedule (which keeps the length that was booked) and the journey has a
  moment asking it; a journey without one books the type's primary length.
  Known once the chosen length is one the type offers, which a `?minutes=`
  link settles on arrival. The slot depends on it (`Facts.Slot`): times are
  offered for a length, so none can be picked before it is known. Choosing
  it never shows the organiser's other types, so a booker who came by a
  direct link may return to it.
  """

  use TymeslotWeb.Themes.Shared.Journey.Fact

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes.Lengths
  alias TymeslotWeb.Live.Scheduling.{AvailabilityHelpers, WeekSlots}
  alias TymeslotWeb.Themes.Shared.ChosenLength
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.Journey.Progress

  @impl Fact
  def key, do: :length

  @impl Fact
  def requires(_assigns), do: [:meeting_type]

  @impl Fact
  def required?(assigns), do: ChosenLength.choose?(assigns) and asked?(assigns)

  @impl Fact
  def known?(assigns),
    do: Lengths.offers?(assigns[:meeting_type], assigns[:chosen_length_minutes])

  @impl Fact
  def events, do: [:select_length]

  # Only a length the type offers is taken; anything else a crafted push
  # sends is ignored. A new length makes the month grid and a loaded week
  # stale, so both are fetched again.
  @impl Fact
  def handle(socket, :select_length, value) do
    minutes = Lengths.parse(value)

    if Lengths.offers?(socket.assigns[:meeting_type], minutes) do
      {:noreply,
       socket
       |> assign(:chosen_length_minutes, minutes)
       |> AvailabilityHelpers.fetch_month_availability_async()
       |> WeekSlots.refetch()}
    else
      {:noreply, socket}
    end
  end

  @impl Fact
  def continue(socket) do
    cond do
      known?(socket.assigns) -> {:done, socket}
      is_nil(socket.assigns[:chosen_length_minutes]) -> {:error, :duration_required}
      true -> {:error, :duration_invalid}
    end
  end

  @impl Fact
  def clear(socket), do: assign(socket, :chosen_length_minutes, nil)

  @doc """
  The moment to show before the slot's when the booker still has a length to
  choose, or nil: a direct link to a type offering several lengths, without
  `?minutes=`, arrives on the calendar and is sent to the choice first.
  """
  @spec pending_moment(map()) :: atom() | nil
  def pending_moment(assigns) do
    if required?(assigns) and not known?(assigns),
      do: Progress.moment_for(assigns.journey, :length)
  end

  defp asked?(%{journey: %{moments: _moments} = journey}),
    do: Progress.moment_for(journey, :length) != nil

  defp asked?(_assigns), do: false
end

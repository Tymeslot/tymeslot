defmodule TymeslotWeb.Themes.Shared.BookingSuccess do
  @moduledoc """
  What a new booking does once the booking page reaches its confirmation:
  sends the booker to the meeting type's redirect address, or tells the
  embedding page about the booking.

  Two steps, because the booking is known before the confirmation is shown.
  `prepare/3` runs where the booking is made and assigns
  `:booking_success`, the redirect address and the `data` map
  `Tymeslot.Bookings.RedirectParams` builds, or nil when this booking sends
  nobody anywhere. `dispatch/1` runs after the transition to the
  confirmation, since a transition may patch the URL, and a patch put on the
  socket after the redirect would replace it:

    * on a page not embedded, with a redirect address, the browser leaves
      for it (`Phoenix.LiveView.redirect/2`, `external:`);
    * in an embed, the page always pushes `"booking_success"` with
      `%{redirect_url: url_or_nil, data: data}`, also without an address,
      since the embedding page's `onSuccess` callback relies on it; the
      `BookingSuccess` hook in `SchedulingPage` hands it on to the parent,
      which does the navigating.

  Nothing is prepared for a booking still awaiting its booker's email
  confirmation: the confirmation step is where they are told to check their
  inbox and can have the link sent again, so neither a redirect nor the
  embedding page's `onSuccess` may take them past it; the booking counts
  only once confirmed, on the verify page. Nor for a reschedule (the booking
  is not new), a simulated booking (`DemoOrchestrator`, a demo organiser: there is no
  meeting, and an owner preview runs inside the dashboard, which must never
  be navigated away), or a caught honeypot (no booking was made).

  The UTM tags passed along are the ones the booker arrived with
  (`:redirect_utm`, `LiveHelpers.Tracking`), captured whether or not
  booking analytics is on.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias Tymeslot.Bookings.RedirectParams
  alias Tymeslot.Demo
  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Live.Scheduling.PreviewMode

  @event "booking_success"

  @doc """
  Assigns `:booking_success` for `meeting`, just booked by `booker` (the
  name and email they booked with, see `RedirectParams.booker/0`; the time
  zone, UTM tags and answers default to the socket's). Assigns nil instead
  for a booking that redirects nowhere (see the moduledoc).
  """
  @spec prepare(LiveView.Socket.t(), map() | nil, map()) :: LiveView.Socket.t()
  def prepare(socket, meeting, booker) do
    if redirects?(socket, meeting) do
      assign(socket, :booking_success, build(socket, meeting, booker))
    else
      assign(socket, :booking_success, nil)
    end
  end

  @doc """
  Redirects or pushes for the booking `prepare/3` assigned, once, and
  clears it. A socket with nothing prepared is returned unchanged.
  """
  @spec dispatch(LiveView.Socket.t()) :: LiveView.Socket.t()
  def dispatch(%{assigns: %{booking_success: %{} = success}} = socket) do
    socket = assign(socket, :booking_success, nil)

    cond do
      socket.assigns[:embedded] -> LiveView.push_event(socket, @event, success)
      is_binary(success.redirect_url) -> LiveView.redirect(socket, external: success.redirect_url)
      true -> socket
    end
  end

  def dispatch(socket), do: socket

  defp redirects?(socket, meeting) do
    is_map(meeting) and not MeetingState.awaiting_verification?(meeting) and
      not (socket.assigns[:is_rescheduling] == true) and
      not PreviewMode.owner_preview?(socket) and not (socket.assigns[:theme_preview] == true) and
      not Demo.demo_mode?(socket)
  end

  defp build(socket, meeting, booker) do
    assigns = socket.assigns

    defaults = %{
      timezone: Map.get(meeting, :attendee_timezone) || assigns[:user_timezone],
      utm: assigns[:redirect_utm] || %{},
      custom_fields_snapshot: assigns[:custom_fields_snapshot] || [],
      custom_field_answers: assigns[:custom_field_answers] || %{}
    }

    RedirectParams.build(assigns[:meeting_type], meeting, Map.merge(defaults, booker))
  end
end

defmodule TymeslotWeb.Themes.Shared.PaymentReturn.Seat do
  @moduledoc """
  Authorisation, lookup and outcome for the return pages of a held group
  seat's Stripe Checkout: `/themes/<slug>/payment-processing/seat/<hold_id>`
  and `/themes/<slug>/payment-cancelled/seat/<hold_id>`
  (`Shared.PaymentReturnLive.SeatProcessing` and `.SeatCancelled`), the URLs
  `Tymeslot.MeetingPayments.CheckoutSessions` gives Stripe for a seat hold.

  A seat's pages are keyed by its hold, never by the group meeting, which is
  shared: its status says how the session stands, not whether this booker's
  seats were paid. The outcome is the hold's (`outcome/3`, decided by
  `Checkout.seat_checkout_outcome/2`), so a hold that lapsed on a session
  others confirmed reads as expired, and a hold that became a seat reads as
  confirmed.

  The processing page is authorised as the meeting's is
  (`PaymentReturn`): the hold exists, its meeting's organiser's theme is the
  URL's (`PaymentReturn.organizer_for_meeting/2`), a payment was opened for
  the hold, and the URL's `session_id` is that payment's checkout session
  (`PaymentReturn.validate_session/2`). The page reads only; the webhook is
  the source of truth.
  """

  alias Ecto.UUID
  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Phoenix.PubSub
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @type ctx :: %{
          hold: SeatHoldSchema.t(),
          meeting: MeetingSchema.t(),
          payment: MeetingPayments.booking_payment(),
          profile: ProfileSchema.t()
        }

  @type outcome :: :loading | :confirmed | :expired | :cancelled | :failed

  @doc """
  The hold `seat_hold_id`, its meeting, its payment and the organiser's
  profile, when the hold's meeting is the organiser's in the URL's theme and
  `session_id` is its payment's checkout session; `{:error, reason}`
  otherwise, never shown to the visitor.
  """
  @spec authorize(String.t(), String.t(), String.t() | nil) :: {:ok, ctx()} | {:error, atom()}
  def authorize(seat_hold_id, theme_slug, session_id) do
    with {:ok, hold, meeting, profile} <- lookup(seat_hold_id, theme_slug),
         {:ok, payment} <- get_payment(hold),
         :ok <- PaymentReturn.validate_session(session_id, payment) do
      {:ok, %{hold: hold, meeting: meeting, payment: payment, profile: profile}}
    end
  end

  @doc """
  The hold `seat_hold_id`, its meeting and the organiser's profile, when the
  organiser's theme is the URL's, with no session check: for the cancelled
  page, which the booker may reach from any point of the checkout.
  """
  @spec lookup(String.t(), String.t()) ::
          {:ok, SeatHoldSchema.t(), MeetingSchema.t(), ProfileSchema.t()} | {:error, atom()}
  def lookup(seat_hold_id, theme_slug) do
    with {:ok, hold} <- get_hold(seat_hold_id),
         {:ok, meeting, profile} <-
           PaymentReturn.organizer_for_meeting(hold.meeting_id, theme_slug) do
      {:ok, hold, meeting, profile}
    end
  end

  @doc """
  Mounts the seat's processing page: subscribes to the hold's topic
  (`SeatHolds.topic/1`) once its id is a UUID, before reading anything, so
  a `{:paid, _}` or `:expired` landing between the two is not missed, then
  authorises the visitor (`authorize/3`) and assigns the page's state
  (`assign_state/2`), the organiser's customisation and profile. A visitor who fails any check
  is sent home with a generic flash (`PaymentReturn.reject/1`). The dead
  render reads only the page's language.
  """
  @spec mount_processing(map(), LiveView.Socket.t(), String.t()) :: {:ok, LiveView.Socket.t()}
  def mount_processing(%{"seat_hold_id" => hold_id} = params, socket, theme_slug) do
    socket =
      PaymentReturn.assign_language_switcher(
        socket,
        PaymentReturn.page_path(theme_slug, "payment-processing", ["seat", hold_id]),
        Map.take(params, ["session_id"])
      )

    if LiveView.connected?(socket) do
      with {:ok, hold_id} <- UUID.cast(hold_id),
           :ok <- PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold_id)),
           {:ok, %{hold: hold, meeting: meeting, payment: payment, profile: profile}} <-
             authorize(hold_id, theme_slug, params["session_id"]) do
        socket =
          socket
          |> PaymentReturn.assign_customization(profile)
          |> PaymentReturn.assign_organizer(profile, as_booked(meeting, hold))
          |> Component.assign(
            rebook_path: PaymentReturn.booking_path(profile, meeting),
            hold_meeting: meeting
          )
          |> assign_state(hold, payment)

        {:ok, socket}
      else
        _invalid_or_refused -> {:ok, PaymentReturn.reject(socket)}
      end
    else
      socket =
        socket
        |> assign_dead_render_language(hold_id, theme_slug)
        |> PaymentReturn.no_customization()
        |> PaymentReturn.no_organizer()
        |> Component.assign(
          loading: true,
          seat_hold: nil,
          meeting: nil,
          payment: nil,
          outcome: :loading,
          series_count: nil,
          rebook_path: nil,
          invitation_held: false,
          invitation_withheld: false
        )

      {:ok, socket}
    end
  end

  @doc """
  Re-reads the hold and its payment after a broadcast on the hold's topic,
  so the page renders what the webhook wrote.
  """
  @spec refresh(LiveView.Socket.t()) :: LiveView.Socket.t()
  def refresh(%{assigns: %{seat_hold: %SeatHoldSchema{id: hold_id}}} = socket) do
    case SeatHolds.get(hold_id) do
      %SeatHoldSchema{} = hold ->
        assign_state(socket, hold, BookingPayments.payment_for_seat_hold(hold_id))

      nil ->
        socket
    end
  end

  def refresh(socket), do: socket

  @doc """
  What the seat's return page tells its booker now: `:loading` on the dead
  render and while the checkout is still processing, else the hold's
  outcome, which the domain decides (`Checkout.seat_checkout_outcome/2`),
  as `PaymentReturn.outcome/3` maps a meeting's.
  """
  @spec outcome(boolean(), SeatHoldSchema.t() | nil, MeetingPayments.booking_payment() | nil) ::
          outcome()
  def outcome(true, _hold, _payment), do: :loading

  def outcome(false, hold, payment) do
    case Checkout.seat_checkout_outcome(hold, payment) do
      :processing -> :loading
      outcome -> outcome
    end
  end

  @doc """
  Assigns the seat's page language on the dead render, as
  `PaymentReturn.assign_dead_render_language/3` does for a meeting, through
  the hold's meeting and in the language the hold was booked in.
  """
  @spec assign_dead_render_language(LiveView.Socket.t(), String.t(), String.t()) ::
          LiveView.Socket.t()
  def assign_dead_render_language(socket, hold_id, theme_slug) do
    case lookup(hold_id, theme_slug) do
      {:ok, hold, meeting, profile} ->
        PaymentReturn.assign_language(socket, profile, as_booked(meeting, hold))

      {:error, _reason} ->
        socket
    end
  end

  @doc """
  The hold's meeting as its booker booked it: in the timezone and language
  the hold snapshotted, since the group meeting has no attendee of its own.
  """
  @spec as_booked(MeetingSchema.t(), SeatHoldSchema.t()) :: MeetingSchema.t()
  def as_booked(%MeetingSchema{} = meeting, %SeatHoldSchema{} = hold),
    do: %{meeting | attendee_timezone: hold.timezone, attendee_locale: hold.locale}

  # The page's state for the hold and its payment. Once the hold became a
  # seat, the meeting shown is that seat's (a late payment can seat the
  # booker on another meeting than the hold's), else the hold's own.
  defp assign_state(socket, hold, payment) do
    Component.assign(socket,
      loading: false,
      seat_hold: hold,
      payment: payment,
      meeting: shown_meeting(hold, socket.assigns.hold_meeting),
      outcome: outcome(false, hold, payment),
      series_count: nil,
      invitation_held: false,
      invitation_withheld: false
    )
  end

  defp shown_meeting(%SeatHoldSchema{status: :converted, participant_id: id} = hold, meeting)
       when is_binary(id) do
    case SeatView.for_participant(id) do
      {:ok, seat} -> seat
      {:error, :not_found} -> as_booked(meeting, hold)
    end
  end

  defp shown_meeting(hold, meeting), do: as_booked(meeting, hold)

  defp get_hold(hold_id) do
    case SeatHolds.get(hold_id) do
      %SeatHoldSchema{} = hold -> {:ok, hold}
      nil -> {:error, :seat_hold_not_found}
    end
  end

  defp get_payment(hold) do
    case BookingPayments.payment_for_seat_hold(hold.id) do
      nil -> {:error, :payment_not_found}
      payment -> {:ok, payment}
    end
  end
end

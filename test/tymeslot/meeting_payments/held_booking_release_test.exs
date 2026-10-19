defmodule Tymeslot.MeetingPayments.HeldBookingReleaseTest do
  @moduledoc """
  A booking waiting for payment holds its slot. When the host disconnects
  Stripe or asks for their account to be deleted, the hold is released: the
  attendee waiting on the payment is told the booking expired, and the
  booking page offers the slot again at once rather than once its cached
  offer has aged out.

  The host is open for a single hour, so the held booking closes the whole
  day on the month view, which the page caches per host.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :availability
  @moduletag :integration

  import Mox, only: [stub: 3, verify_on_exit!: 1]
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Auth
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"
  @account "acct_HELD_RELEASE"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    on_exit(&AvailabilityCache.clear_all/0)
    with_config(:tymeslot, account_deletion_grace_days: 14, account_deletion_hook: nil)

    stub(StripeAdapterMock, :expire_checkout_session, fn session, _opts ->
      {:ok, %{"id" => session, "status" => "expired"}}
    end)

    %{user: host, profile: profile} =
      create_bookable_profile(
        timezone: @timezone,
        hours: %{is_available: true, start_time: ~T[11:00:00], end_time: ~T[12:00:00]}
      )

    {:ok, _account} = ConnectAccountQueries.insert_placeholder(host.id, "ch")
    date = next_bookable_weekday()
    meeting = hold_slot(host, date, ~T[11:00:00])

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(meeting.id))

    # The booking page has already read, and cached, its month view with the
    # slot held.
    refute bookable?(profile, date)

    %{host: host, profile: profile, date: date, meeting: meeting}
  end

  test "disconnecting Stripe releases the slot and tells the waiting attendee", context do
    assert {:ok, %{cancelled_count: 1}} = MeetingPayments.disconnect(context.host)

    assert_released(context)
  end

  test "asking for account deletion releases the slot and tells the waiting attendee",
       context do
    assert {:ok, _pending} =
             Auth.request_account_deletion(
               context.host,
               %{"current_password" => "Password123!"},
               ip: "203.0.113.9",
               user_agent: "ExUnit"
             )

    assert %{success: 1} = Oban.drain_queue(queue: :payments)

    assert_released(context)
  end

  defp assert_released(%{meeting: meeting, profile: profile, date: date}) do
    assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
    assert_receive :expired, 1_000
    assert bookable?(profile, date)
  end

  defp hold_slot(host, date, time) do
    start_time = DateTime.new!(date, time, @timezone)

    meeting =
      insert(:meeting,
        status: "awaiting_payment",
        organizer_user_id: host.id,
        organizer_email: host.email,
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute),
        duration: 60
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: host.id,
      stripe_account_id: @account,
      stripe_checkout_session_id: "cs_HELD_#{meeting.id}"
    )

    meeting
  end

  # The day as the booking page's month view reads it: through the cached
  # offer, which is not cleared here, so only a released cache reopens it.
  defp bookable?(profile, date) do
    request = %{profile: profile, user_timezone: @timezone}
    {:ok, days} = Offer.days_in_range(request, date, date, 60)
    Map.fetch!(days, Date.to_iso8601(date))
  end
end

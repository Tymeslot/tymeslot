defmodule Tymeslot.Bookings.CreateGroupPaidTest do
  @moduledoc false

  # async: false: the payment and feature-access config are global env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.CreateGroup
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.SeatPaymentQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.Test.EnqueuedJobs
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.SlackWorker
  alias Tymeslot.Workers.TelegramWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 0
    )

    TestMocks.stub_no_calendar_events()

    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    profile = insert(:profile, user: user)
    # The subject is the paid seat, so the schedule never refuses a booking.
    _schedule = open_schedule_for(profile)

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_HOST",
      default_currency: "eur",
      charges_enabled: true
    )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Paid Class",
        max_participants: 4,
        allow_guests: true,
        payment_required: true,
        price_cents: 2000
      )

    meeting_params = %{
      date: Date.add(Date.utc_today(), 5),
      time: "10:00",
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    %{user: user, meeting_type: meeting_type, meeting_params: meeting_params}
  end

  defp execute(ctx, email, extra_params \\ %{}) do
    Create.execute(
      Map.merge(ctx.meeting_params, extra_params),
      %{"name" => "Booker #{email}", "email" => email, "message" => "hello"}
    )
  end

  defp expect_checkout(:ok) do
    StripeStub.expect(:create_checkout_session, fn %{form: form} ->
      StripeFixtures.object("checkout_session_payment", %{
        "id" => "cs_" <> form["client_reference_id"],
        "url" => "https://checkout.stripe.com/x"
      })
    end)
  end

  # The meeting is only known once the seat transaction has run, so the test
  # subscribes to its payment topic as the checkout is opened for it.
  defp expect_checkout(:error) do
    StripeStub.expect(:create_checkout_session, fn %{form: form} ->
      :ok =
        Phoenix.PubSub.subscribe(
          Tymeslot.PubSub,
          Checkout.payment_topic(form["payment_intent_data"]["metadata"]["meeting_id"])
        )

      {:error_fixture, "api_error"}
    end)
  end

  defp expect_checkout, do: expect_checkout(:ok)

  defp hold_for(email), do: Repo.get_by!(SeatHoldSchema, email: email)

  test "booking a paid group slot returns a checkout and holds the seats", ctx do
    expect_checkout()

    assert {:ok, :payment_required,
            %{meeting: meeting, seat_hold: %{seats: 2} = hold, checkout_url: url}} =
             execute(ctx, "one@example.com", %{guest_emails: ["guest@example.com"]})

    assert url == "https://checkout.stripe.com/x"
    assert meeting.status == :awaiting_payment
    assert hold.meeting_id == meeting.id
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
    assert Seats.seats_left(meeting, 4) == 2

    payment = SeatPaymentQueries.by_seat_hold_id(hold.id)
    assert payment.amount_cents == 4000
    assert payment.seats == 2

    assert EnqueuedJobs.for_user(ctx.user) == []
  end

  # The booking form prices its submit with `CreateGroup.seats_for/3`; the
  # hold must take, and the checkout charge, exactly those seats.
  test "a guest who is the booker takes no seat of their own, priced or held", ctx do
    expect_checkout()
    guests = ["One@Example.com ", "guest@example.com", "guest@example.com"]

    assert CreateGroup.seats_for(guests, "one@example.com", ctx.meeting_type) == 2

    assert {:ok, :payment_required, %{seat_hold: %{seats: 2} = hold}} =
             execute(ctx, "one@example.com", %{guest_emails: guests})

    assert %{seats: 2, amount_cents: 4000} = SeatPaymentQueries.by_seat_hold_id(hold.id)
  end

  describe "CreateGroup.seats_for/3" do
    test "counts the booker alone with no guests", ctx do
      assert CreateGroup.seats_for([], "one@example.com", ctx.meeting_type) == 1
      assert CreateGroup.seats_for(nil, "one@example.com", ctx.meeting_type) == 1
    end

    test "drops invalid addresses and caps guests at the type's limit", ctx do
      meeting_type = %{ctx.meeting_type | max_guests_per_booking: 2}
      guests = ["a@example.com", "not-an-email", "b@example.com", "c@example.com"]

      assert CreateGroup.seats_for(guests, "one@example.com", meeting_type) == 3
    end

    test "counts no guests on a type that takes none", ctx do
      meeting_type = %{ctx.meeting_type | allow_guests: false}

      assert CreateGroup.seats_for(["a@example.com"], "one@example.com", meeting_type) == 1
    end
  end

  test "a seat hold fires no automation", ctx do
    insert(:webhook, user: ctx.user, events: ["meeting.created"])
    insert(:slack_integration, user: ctx.user)
    insert(:telegram_integration, user: ctx.user)
    expect_checkout()

    assert {:ok, :payment_required, %{seat_hold: %{status: :held}}} =
             execute(ctx, "one@example.com")

    refute_enqueued(worker: WebhookWorker)
    refute_enqueued(worker: SlackWorker)
    refute_enqueued(worker: TelegramWorker)
  end

  test "a failed checkout releases the hold and the slot", ctx do
    expect_checkout(:error)

    assert {:error, :checkout_failed} =
             execute(ctx, "one@example.com", %{guest_emails: ["guest@example.com"]})

    hold = hold_for("one@example.com")
    assert %{status: :released, released_reason: :failed} = hold
    assert SeatPaymentQueries.by_seat_hold_id(hold.id).status == :failed

    meeting = Repo.get!(MeetingSchema, hold.meeting_id)
    assert meeting.status == :expired
    assert Seats.seats_left(meeting, 4) == 4
    # A seat's outcome goes to its hold's topic, never the shared meeting's.
    refute_receive :expired
  end

  test "a failed checkout on a joined meeting leaves the meeting alone", ctx do
    expect_checkout()

    assert {:ok, :payment_required, %{meeting: meeting, seat_hold: first}} =
             execute(ctx, "one@example.com")

    # The first booker has paid: their hold became a participant and the
    # meeting was confirmed.
    meeting = meeting |> Changeset.change(status: :confirmed) |> Repo.update!()
    insert(:participant, meeting: meeting, email: "one@example.com")
    first |> Changeset.change(status: :converted) |> Repo.update!()

    expect_checkout(:error)
    assert {:error, :checkout_failed} = execute(ctx, "two@example.com")

    hold = hold_for("two@example.com")
    assert %{status: :released, released_reason: :failed} = hold
    assert SeatPaymentQueries.by_seat_hold_id(hold.id).status == :failed
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    assert Seats.seats_left(meeting, 4) == 3
    refute_receive :expired
  end

  test "a failed checkout beside another booker's open hold keeps the meeting held", ctx do
    expect_checkout()
    assert {:ok, :payment_required, %{meeting: meeting}} = execute(ctx, "one@example.com")

    expect_checkout(:error)
    assert {:error, :checkout_failed} = execute(ctx, "two@example.com")

    assert SeatPaymentQueries.by_seat_hold_id(hold_for("two@example.com").id).status == :failed
    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_payment
    assert SeatHolds.seats_held(meeting.id) == 1
    refute_receive :expired
  end

  # The first checkout is still open: the booker is told to finish it, not
  # that they have a seat.
  test "the same email cannot hold a seat twice", ctx do
    expect_checkout()
    assert {:ok, :payment_required, %{meeting: meeting}} = execute(ctx, "one@example.com")

    assert {:error, :seat_held} = execute(ctx, "ONE@example.com")
    assert SeatHolds.seats_held(meeting.id) == 1
  end

  test "a full slot is refused before any checkout", ctx do
    expect_checkout()

    assert {:ok, :payment_required, _result} =
             execute(ctx, "one@example.com", %{
               guest_emails: ["a@example.com", "b@example.com", "c@example.com"]
             })

    assert {:error, :slot_taken} = execute(ctx, "two@example.com")
  end

  test "a free group type books a participant as before", ctx do
    ctx.meeting_type
    |> Changeset.change(payment_required: false, price_cents: nil)
    |> Repo.update!()

    assert {:ok, %MeetingSchema{} = meeting} = execute(ctx, "one@example.com")
    assert meeting.status == :confirmed
    assert [%{email: "one@example.com"}] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert SeatHolds.seats_held(meeting.id) == 0
    assert_enqueued(worker: CalendarEventWorker, args: %{"meeting_id" => meeting.id})
  end
end

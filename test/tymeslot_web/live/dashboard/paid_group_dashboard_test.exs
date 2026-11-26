defmodule TymeslotWeb.Dashboard.PaidGroupDashboardTest do
  @moduledoc """
  A paid group session as its host sees it on the dashboard: what each
  participant paid, the cancel dialog's choice between refunding everyone
  and refunding no one, the payments page naming the session a seat paid
  for and refunding one seat on its own, and the slots that only hold seats
  for bookers still paying, which nobody has booked yet.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.GroupCancellationTestHelpers

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.CalendarGrid
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Components.CoreComponents.Feedback

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup %{conn: conn} do
    TestMocks.setup_calendar_mocks()
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context -> {:error, :none} end)

    ctx =
      host_and_session(start_time: ~U[2027-03-04 10:00:00Z], end_time: ~U[2027-03-04 10:30:00Z])

    host =
      ctx.host
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host)

    Map.merge(ctx, %{conn: conn, host: host})
  end

  defp open_cancel_dialog(conn, session) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{session.id}") |> render_click()
    view
  end

  # The refunds the host's cancellation recorded.
  defp refund_jobs,
    do: Repo.all(from(r in RefundSchema, where: r.source == :cancellation))

  defp status(meeting), do: Repo.get!(MeetingSchema, meeting.id).status

  describe "the participants panel" do
    test "a paid participant shows what they paid", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", seats: 2, amount_cents: 4000)
      free = insert(:participant, meeting: ctx.session, email: "ben@example.com", name: "Ben")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert [pill] =
               view
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("[data-testid=participant-payment]")

      assert Floki.text(pill) =~ "€40.00 paid · 2 seats"

      refute has_element?(
               view,
               "li[data-participant-id='#{free.id}'] [data-testid=participant-payment]"
             )
    end

    test "a refunded participant shows refunded", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", status: :refunded, refunded_amount_cents: price_cents())

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert has_element?(view, "[data-testid=participant-payment]", "Refunded")
      refute has_element?(view, "[data-testid=participant-payment]", "paid")
    end

    test "a partly refunded participant shows how much, apart from a full refund",
         %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", status: :partially_refunded, refunded_amount_cents: 500)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert [pill] =
               view
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("[data-testid=participant-payment]")

      assert Floki.text(pill) =~ "€5.00 refunded"
      assert [class] = Floki.attribute(pill, "class")
      assert class =~ Feedback.pill_tone_class(:warning)
      refute class =~ Feedback.pill_tone_class(:neutral)
    end

    test "a disputed participant shows disputed", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", status: :disputed)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert has_element?(view, "[data-testid=participant-payment]", "Disputed")
      refute has_element?(view, "[data-testid=participant-payment]", "paid")
    end
  end

  describe "cancelling a paid group session" do
    test "offers refund everyone or no one", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", amount_cents: 3000)
      paid_seat(ctx, "grace@example.com", amount_cents: 3000)

      view = open_cancel_dialog(conn, ctx.session)

      assert has_element?(
               view,
               "#cancel-meeting-form",
               "2 participants paid for this session (€60.00 still held)."
             )

      assert has_element?(view, "input[name=cancel_refund_choice][value=full][checked]")
      assert has_element?(view, "input[name=cancel_refund_choice][value=none]")
      refute has_element?(view, "input[name=cancel_refund_choice][value=partial]")
      refute has_element?(view, "input[name=cancel_refund_amount]")
    end

    test "one paid participant is named in the singular", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", amount_cents: 3000)

      view = open_cancel_dialog(conn, ctx.session)

      assert has_element?(
               view,
               "#cancel-meeting-form",
               "1 participant paid for this session (€30.00 still held)."
             )
    end

    test "a seat paid while the dialog was open is shown before anything is cancelled",
         %{conn: conn} = ctx do
      view = open_cancel_dialog(conn, ctx.session)
      refute has_element?(view, "input[name=cancel_refund_choice]")

      paid_seat(ctx, "ada@example.com")
      view |> form("#cancel-meeting-form") |> render_submit()

      assert has_element?(
               view,
               "#cancel-refund-payments-error",
               "The payments for this meeting changed while this was open."
             )

      assert has_element?(view, "#cancel-meeting-form", "1 participant paid for this session")
      assert has_element?(view, "input[name=cancel_refund_choice][value=full][checked]")
      assert status(ctx.session) == :confirmed
      assert refund_jobs() == []

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert status(ctx.session) == :cancelled
      assert length(refund_jobs()) == 1
    end

    test "a seat refunded while the dialog was open is shown before anything is cancelled",
         %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com")
      refunded = paid_seat(ctx, "grace@example.com")

      view = open_cancel_dialog(conn, ctx.session)
      assert has_element?(view, "#cancel-meeting-form", "2 participants paid for this session")

      refunded
      |> Changeset.change(status: :refunded, refunded_amount_cents: refunded.amount_cents)
      |> Repo.update!()

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert has_element?(
               view,
               "#cancel-refund-payments-error",
               "The payments for this meeting changed while this was open."
             )

      refute render(view) =~ "Someone paid for a seat"
      assert has_element?(view, "#cancel-meeting-form", "1 participant paid for this session")
      assert status(ctx.session) == :confirmed
      assert refund_jobs() == []
    end

    test "a seat paid outside the refund window is left for Stripe, and said so",
         %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", amount_cents: 3000)

      paid_seat(ctx, "old@example.com",
        amount_cents: 2500,
        paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)
      )

      view = open_cancel_dialog(conn, ctx.session)

      assert has_element?(
               view,
               "#cancel-meeting-form",
               "Cancelling won't refund 1 participant (€25.00): their payment is older than the 60-day refund window. You can refund it from Stripe."
             )

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert status(ctx.session) == :cancelled
      assert [%{amount_cents: 3000}] = refund_jobs()
      assert render(view) =~ "Session cancelled. Refunds are on their way."
    end

    test "a full refund with every seat outside the refund window says none was refunded",
         %{conn: conn} = ctx do
      paid_seat(ctx, "old@example.com",
        amount_cents: 2500,
        paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)
      )

      view = open_cancel_dialog(conn, ctx.session)

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert status(ctx.session) == :cancelled
      assert refund_jobs() == []
      html = render(view)
      refute html =~ "Refunds are on their way."

      assert html =~
               "Session cancelled. No payment could be refunded automatically: they are older than the 60-day refund window. You can refund them from Stripe."
    end

    test "with full refunds schedules a refund per seat", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com")
      paid_seat(ctx, "grace@example.com")

      view = open_cancel_dialog(conn, ctx.session)

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert status(ctx.session) == :cancelled
      assert length(refund_jobs()) == 2
      assert render(view) =~ "Session cancelled. Refunds are on their way."
    end

    test "without refund needs the acknowledgement", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com")

      view = open_cancel_dialog(conn, ctx.session)

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "none"})
      |> render_submit()

      assert has_element?(
               view,
               "#cancel-refund-ack-error",
               "Tick the acknowledgement to cancel without refunding the participants."
             )

      assert has_element?(
               view,
               "input[name=cancel_refund_no_refund_ack][aria-describedby=cancel-refund-ack-error]"
             )

      assert has_element?(view, "input[name=cancel_refund_choice][value=none][checked]")
      assert status(ctx.session) == :confirmed

      view
      |> form("#cancel-meeting-form", %{
        "cancel_refund_choice" => "none",
        "cancel_refund_no_refund_ack" => "true"
      })
      |> render_submit()

      assert status(ctx.session) == :cancelled
      assert refund_jobs() == []
      assert render(view) =~ "Meeting cancelled successfully"
    end
  end

  describe "the payments page" do
    setup do
      previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
      previous_enabled = Application.get_env(:tymeslot, :meeting_payments_enabled)

      Application.put_env(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Features.DefaultAccessChecker
      )

      Application.put_env(:tymeslot, :meeting_payments_enabled, true)

      on_exit(fn ->
        if previous_checker,
          do: Application.put_env(:tymeslot, :feature_access_checker, previous_checker),
          else: Application.delete_env(:tymeslot, :feature_access_checker)

        Application.put_env(:tymeslot, :meeting_payments_enabled, previous_enabled)
      end)

      :ok
    end

    setup %{host: host} do
      insert(:connect_account,
        user: host,
        stripe_account_id: account(),
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      :ok
    end

    test "the payments table names the session of a seat payment", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com",
        seats: 2,
        amount_cents: 4000,
        meeting_type_name: "Group Class"
      )

      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
      table = view |> element("[data-testid=payments-table]") |> render()

      assert table =~ "Group Class · Thu 4 Mar"
      assert table =~ "10:00"
      assert table =~ "2 seats"
    end

    test "a seat payment whose session is gone is named by its type alone",
         %{conn: conn, host: host} do
      insert(:paid_booking_payment,
        meeting_id: nil,
        seat_payment: true,
        meeting_type_name: "Group Class",
        host_user_id: host.id,
        host_email: host.email,
        stripe_account_id: account()
      )

      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
      table = view |> element("[data-testid=payments-table]") |> render()

      assert table =~ "Group Class"
      refute table =~ "Group Class ·"
    end

    # A participant who left keeps their seat's money with the host, and a
    # full refund of the session's seats refunds only the seats still held.
    test "a seat its participant left is still owed after the session is cancelled with refunds",
         %{conn: conn, host: host} = ctx do
      left = paid_seat(ctx, "ada@example.com")
      paid_seat(ctx, "grace@example.com")

      ParticipantSchema
      |> Repo.get!(left.participant_id)
      |> Changeset.change(cancelled_at: ~U[2027-03-01 09:00:00Z])
      |> Repo.update!()

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, host.id, :refund_seats)

      assert length(refund_jobs()) == 1

      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      assert has_element?(view, "#outstanding-refund-#{left.id}", "Left 1 Mar 2027")
    end

    test "refunding a seat payment from the payments page refunds that seat only",
         %{conn: conn} = ctx do
      refunded = paid_seat(ctx, "ada@example.com")
      kept = paid_seat(ctx, "grace@example.com")

      StripeStub.expect(:create_refund, fn %{form: form} = request ->
        assert form["charge"] == refunded.stripe_charge_id
        StripeStubResponses.refund(request, "re_seat")
      end)

      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      view
      |> with_target("#payments-settings")
      |> render_click("open_refund_modal", %{"id" => refunded.id})

      view |> form("#refund-form", %{"refund_type" => "full"}) |> render_submit()
      render_async(view, 2_000)

      assert BookingPaymentQueries.get(refunded.id).refunded_amount_cents == price_cents()
      assert BookingPaymentQueries.get(kept.id).refunded_amount_cents == 0
      assert status(ctx.session) == :confirmed
    end
  end

  describe "seats held for bookers still paying" do
    defp grid_window,
      do: {~U[2027-03-01 00:00:00Z], ~U[2027-03-08 00:00:00Z]}

    test "a hold-only meeting does not appear on the dashboard",
         %{conn: conn, host: host} = ctx do
      held =
        insert(:group_meeting,
          organizer_user: host,
          organizer_email: host.email,
          meeting_type_ref: ctx.meeting_type,
          title: "Held Only",
          start_time: ~U[2027-03-05 10:00:00Z],
          end_time: ~U[2027-03-05 10:30:00Z],
          capacity: 6,
          status: :awaiting_payment
        )

      open_hold(%{ctx | session: held}, "payer@example.com")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      assert has_element?(view, "#cancel-meeting-#{ctx.session.id}")
      refute has_element?(view, "#cancel-meeting-#{held.id}")

      {from, to} = grid_window()

      ids =
        host.id
        |> CalendarGrid.list_booking_events_for_range(from, to)
        |> Enum.map(& &1.meeting_id)

      assert ctx.session.id in ids
      refute held.id in ids
    end

    test "the calendar grid counts paid seats, not holds", %{host: host} = ctx do
      paid_seat(ctx, "ada@example.com")
      open_hold(ctx, "payer@example.com")

      {from, to} = grid_window()

      assert [event] = CalendarGrid.list_booking_events_for_range(host.id, from, to)
      assert event.meeting_id == ctx.session.id
      assert event.seats_taken == 1
    end
  end
end

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

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.GroupCancellationTestHelpers

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.CalendarGrid
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.GroupCancelRefund
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

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

  defp refund_jobs, do: all_enqueued(worker: GroupCancelRefund)

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

      refute view
             |> element("li", free.email)
             |> render() =~ "participant-payment"
    end

    test "a refunded participant shows refunded", %{conn: conn} = ctx do
      paid_seat(ctx, "ada@example.com", status: :refunded, refunded_amount_cents: price_cents())

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert has_element?(view, "[data-testid=participant-payment]", "Refunded")
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
               "2 participants paid for this session (€60.00 in total)."
             )

      assert has_element?(view, "input[name=cancel_refund_choice][value=full][checked]")
      assert has_element?(view, "input[name=cancel_refund_choice][value=none]")
      refute has_element?(view, "input[name=cancel_refund_choice][value=partial]")
      refute has_element?(view, "input[name=cancel_refund_amount]")
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

      assert has_element?(view, "#cancel-refund-ack-error")
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

    test "refunding a seat payment from the payments page refunds that seat only",
         %{conn: conn} = ctx do
      refunded = paid_seat(ctx, "ada@example.com")
      kept = paid_seat(ctx, "grace@example.com")

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == refunded.stripe_charge_id
        {:ok, %{id: "re_seat"}}
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

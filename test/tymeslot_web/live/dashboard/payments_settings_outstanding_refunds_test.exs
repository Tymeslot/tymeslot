defmodule TymeslotWeb.Dashboard.PaymentsSettingsOutstandingRefundsTest do
  @moduledoc """
  The payments screen's "Refunds outstanding" card.

  The recent-payments table cannot answer this question: it shows payment
  status without meeting status, so an unrefunded cancellation looks exactly
  like a booking that is still going ahead, and its 25-row window drops older
  ones off the screen. These tests pin that a cancelled booking still holding
  the attendee's money is visible and refundable from here, that it is scoped
  to its own host, and that a row past the 60-day window says so rather than
  offering a button that would fail.
  """

  use TymeslotWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Repo

  @moduletag :payments
  @moduletag :live

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
      if previous_checker do
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      else
        Application.delete_env(:tymeslot, :feature_access_checker)
      end

      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_enabled)
    end)

    :ok
  end

  defp connected_host do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_#{System.unique_integer([:positive])}",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

    user
  end

  defp cancelled_payment_for(user, attrs \\ %{}) do
    meeting = insert(:meeting, status: "cancelled", cancelled_at: DateTime.utc_now(:second))

    defaults = %{
      host_user_id: user.id,
      host_email: user.email,
      stripe_account_id: "acct_REFUND",
      meeting: meeting,
      attendee_email: "outofpocket@example.com",
      amount_cents: 5000,
      currency: "eur"
    }

    insert(:paid_booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  # The same payment legitimately appears in the recent-payments table too, so
  # every assertion about this card's controls is scoped to the card.
  defp refund_button(payment),
    do: "#outstanding-refunds button[phx-value-id='#{payment.id}']"

  defp open_payments(conn, user) do
    conn = log_in_user(conn, user)
    {:ok, view, html} = live(conn, "/dashboard/integrations?tab=payments")
    {view, html}
  end

  describe "the card" do
    test "shows a cancelled booking whose money the host still holds", %{conn: conn} do
      host = connected_host()
      cancelled_payment_for(host)

      {_view, html} = open_payments(conn, host)

      assert html =~ "Refunds outstanding"
      assert html =~ "outofpocket@example.com"
      assert html =~ "€50.00"
    end

    test "explains a cancelled row as a cancellation", %{conn: conn} do
      host = connected_host()
      cancelled_at = ~U[2026-03-14 10:00:00Z]

      payment =
        cancelled_payment_for(host, %{
          meeting: insert(:meeting, status: "cancelled", cancelled_at: cancelled_at)
        })

      {view, html} = open_payments(conn, host)

      assert html =~ "Cancelling never refunds on its own"
      refute html =~ "Expired bookings were paid for but never confirmed"
      assert has_element?(view, "#outstanding-refund-#{payment.id}", "Cancelled 14 Mar 2026")
    end

    # A payment that completed after its slot was taken leaves its booking
    # expired, with no cancellation date, and refunds it automatically.
    test "explains an expired row as an automatic refund, dated by its payment",
         %{conn: conn} do
      host = connected_host()

      payment =
        cancelled_payment_for(host, %{
          meeting: insert(:meeting, status: "expired"),
          paid_at: ~U[2026-09-30 08:00:00Z]
        })

      {view, html} = open_payments(conn, host)

      assert html =~ "Expired bookings were paid for but never confirmed"
      assert html =~ "if one is still listed later, refund it here or in Stripe."
      refute html =~ "Cancelling never refunds on its own"
      assert has_element?(view, "#outstanding-refund-#{payment.id}", "Expired, paid 30 Sep 2026")
    end

    # The card shows a bounded window and says how much it leaves out; the
    # rows it shows are the oldest, an expired row placed by its payment
    # date among the cancellations, so the newest of 51 is the one left out.
    test "shows the oldest outstanding refunds when there are more than it lists",
         %{conn: conn} do
      host = connected_host()
      now = DateTime.utc_now(:second)

      cancelled =
        for hour <- 1..50 do
          meeting =
            insert(:meeting, status: "cancelled", cancelled_at: DateTime.add(now, -hour, :hour))

          cancelled_payment_for(host, %{meeting: meeting})
        end

      newest =
        cancelled_payment_for(host, %{meeting: insert(:meeting, status: "expired"), paid_at: now})

      {view, html} = open_payments(conn, host)

      assert html =~ "Showing the 50 oldest of 51 outstanding refunds."
      refute has_element?(view, "#outstanding-refund-#{newest.id}")
      assert Enum.all?(cancelled, &has_element?(view, "#outstanding-refund-#{&1.id}"))
    end

    test "shows only the balance left after a partial refund", %{conn: conn} do
      host = connected_host()

      cancelled_payment_for(host, %{
        status: "partially_refunded",
        refunded_amount_cents: 2000
      })

      {_view, html} = open_payments(conn, host)

      assert html =~ "€30.00"
    end

    test "is absent entirely when nothing is outstanding", %{conn: conn} do
      host = connected_host()

      cancelled_payment_for(host, %{status: "refunded", refunded_amount_cents: 5000})

      {_view, html} = open_payments(conn, host)

      refute html =~ "Refunds outstanding"
    end

    test "is absent when the meeting is still going ahead", %{conn: conn} do
      host = connected_host()
      meeting = insert(:meeting, status: "confirmed")

      insert(:paid_booking_payment,
        host_user_id: host.id,
        host_email: host.email,
        meeting: meeting
      )

      {_view, html} = open_payments(conn, host)

      refute html =~ "Refunds outstanding"
    end

    test "never shows another host's outstanding cancellation", %{conn: conn} do
      viewer = connected_host()
      other = connected_host()
      cancelled_payment_for(other, %{attendee_email: "theirs@example.com"})

      {_view, html} = open_payments(conn, viewer)

      refute html =~ "theirs@example.com"
      refute html =~ "Refunds outstanding"
    end
  end

  # Declining a paid request refunds it there and then, so the card only
  # meets a declined booking whose automatic refund failed, and must not tell
  # the host that cancelling never refunds.
  describe "a declined request" do
    defp declined_paid_request(host, meeting_attrs \\ %{}) do
      meeting =
        insert(
          :meeting,
          Map.merge(
            %{
              status: "awaiting_approval",
              organizer_user_id: host.id,
              approval_requested_at: DateTime.utc_now(:second),
              approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
            },
            meeting_attrs
          )
        )

      payment =
        cancelled_payment_for(host, %{
          meeting: meeting,
          stripe_charge_id: "ch_DECLINED_#{System.unique_integer([:positive])}",
          paid_at: DateTime.utc_now(:second)
        })

      capture_log(fn ->
        assert {:ok, _declined} = Approval.decline(meeting, "Double-booked")
      end)

      payment
    end

    test "explains a row whose automatic refund failed as a decline", %{conn: conn} do
      host = connected_host()
      Mox.stub(StripeAdapterMock, :create_refund, fn _params, _opts -> {:error, :api_error} end)

      payment = declined_paid_request(host)

      {view, html} = open_payments(conn, host)

      assert html =~
               "You declined these bookings, but their automatic refund didn&#39;t go through. Refund them here or in Stripe."

      refute html =~ "Cancelling never refunds on its own"
      assert has_element?(view, "#outstanding-refund-#{payment.id}", "Declined ")
      assert has_element?(view, refund_button(payment))
    end

    test "lists nothing once the automatic refund has gone through", %{conn: conn} do
      host = connected_host()
      Mox.stub(StripeAdapterMock, :create_refund, fn _params, _opts -> {:ok, %{id: "re_OK"}} end)

      declined_paid_request(host)

      {_view, html} = open_payments(conn, host)

      refute html =~ "Refunds outstanding"
    end

    # A confirmed meeting sent back for approval by a reschedule is not
    # refunded when declined; the host chooses, as for a cancellation.
    test "explains a re-requested meeting, which declining never refunds, as a cancellation",
         %{conn: conn} do
      host = connected_host()

      payment = declined_paid_request(host, %{first_announced_at: DateTime.utc_now(:second)})

      {view, html} = open_payments(conn, host)

      assert html =~ "Cancelling never refunds on its own"
      refute html =~ "You declined these bookings"
      assert has_element?(view, "#outstanding-refund-#{payment.id}")
    end
  end

  describe "refunding from the card" do
    test "the row offers a refund that opens the modal", %{conn: conn} do
      host = connected_host()
      payment = cancelled_payment_for(host)

      {view, _html} = open_payments(conn, host)

      assert has_element?(view, refund_button(payment)),
             "the outstanding row must offer a refund button"

      view |> element(refund_button(payment)) |> render_click()

      assert has_element?(view, "#refund-modal")
    end

    # A payment that completed after its slot was taken leaves its booking
    # expired, with no cancellation date, while the money is still owed.
    test "an expired booking paid after its slot was taken can be refunded", %{conn: conn} do
      host = connected_host()
      payment = cancelled_payment_for(host, %{meeting: insert(:meeting, status: "expired")})

      Mox.stub(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.amount == 5000
        {:ok, %{id: "re_EXPIRED"}}
      end)

      {view, _html} = open_payments(conn, host)

      view |> element(refund_button(payment)) |> render_click()

      view
      |> form("#refund-form", %{"refund_type" => "full"})
      |> render_submit()

      assert Repo.reload!(payment).status == "refunded"
      refute has_element?(view, refund_button(payment))
    end

    # Past 60 days only the host's Stripe dashboard can settle it, so the row
    # stays listed (the debt is real) but offers no button that would fail.
    test "a row past the refund window points at Stripe instead", %{conn: conn} do
      host = connected_host()

      payment =
        cancelled_payment_for(host, %{
          paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)
        })

      {view, html} = open_payments(conn, host)

      assert html =~ "Refunds outstanding"
      assert html =~ "Refund in Stripe"
      refute has_element?(view, refund_button(payment))
    end
  end

  # The card used to live inside the "has a connect account" branch, so the one
  # record inside Tymeslot that the host was still holding an attendee's money
  # vanished at exactly the moment it mattered most. The soft delete detaches
  # the account row from the user, so there is nothing to resurrect: the card
  # has to work with no account at all.
  describe "disconnecting Stripe" do
    test "warns about the outstanding refunds before the host confirms", %{conn: conn} do
      host = connected_host()
      cancelled_payment_for(host)

      {view, _html} = open_payments(conn, host)

      html =
        view |> element("button[phx-click='open_disconnect_modal']") |> render_click()

      assert html =~ "You still owe 1 refund totalling €50.00"
      assert html =~ "refund it from your Stripe dashboard"
    end

    test "leaves the debt on screen, pointing at Stripe", %{conn: conn} do
      host = connected_host()
      payment = cancelled_payment_for(host)

      {view, _html} = open_payments(conn, host)
      assert has_element?(view, refund_button(payment))

      view |> element("button[phx-click='open_disconnect_modal']") |> render_click()

      html =
        view
        |> element("#disconnect-modal [data-testid='confirm-disconnect-stripe']")
        |> render_click()

      # The Connect call-to-action is back, and the debt is still above it.
      assert html =~ "Refunds outstanding"
      assert html =~ "outofpocket@example.com"
      assert html =~ "€50.00"
      assert html =~ "Refund in Stripe"
      assert html =~ "Your Stripe account is not connected"
      refute has_element?(view, refund_button(payment))
    end
  end
end

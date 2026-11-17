defmodule TymeslotWeb.Dashboard.PaymentsLedgerTest do
  @moduledoc """
  What the host's payments page lists: real charges only. A checkout the
  attendee never paid (still pending, or failed with nothing captured) is
  left out, while every row that moved money stays, including a late payment
  on a booking that had already expired. The disconnect and currency
  controls still account for checkouts in progress, in wording that does not
  point at rows the list no longer shows.
  """
  use TymeslotWeb.ConnCase, async: false

  @moduletag :database
  @moduletag :payments

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  setup %{conn: conn} do
    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
    previous_enabled = Application.get_env(:tymeslot, :meeting_payments_enabled)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    on_exit(fn ->
      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_enabled)

      if previous_checker,
        do: Application.put_env(:tymeslot, :feature_access_checker, previous_checker),
        else: Application.delete_env(:tymeslot, :feature_access_checker)
    end)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_LEDGER",
      default_currency: "eur",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  test "lists real charges and leaves out checkouts that were never paid", %{
    conn: conn,
    user: user
  } do
    # A late payment refused because its booking had already expired: money
    # moved, so the host must see it.
    expired = insert(:meeting, organizer_user_id: user.id, status: :expired)
    payment(user, :paid_booking_payment, "late@example.com", meeting_id: expired.id)

    payment(user, :paid_booking_payment, "refunded@example.com",
      status: :refunded,
      refunded_amount_cents: 5000
    )

    payment(user, :booking_payment, "pending@example.com", status: :pending)
    payment(user, :booking_payment, "failed@example.com", status: :failed, paid_at: nil)

    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
    table = view |> element("[data-testid='payments-table']") |> render()

    assert table =~ "late@example.com"
    assert table =~ "refunded@example.com"
    refute table =~ "pending@example.com"
    refute table =~ "failed@example.com"
  end

  test "the disconnect warning still counts checkouts in progress", %{conn: conn, user: user} do
    payment(user, :booking_payment, "pending@example.com", status: :pending)

    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
    view |> element("button[phx-click=open_disconnect_modal]") |> render_click()

    assert view |> element("#disconnect-modal") |> render() =~
             "1 checkout still in progress will be cancelled when you disconnect."
  end

  test "a currency change during a checkout says why it was refused", %{conn: conn, user: user} do
    insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

    view
    |> element("button[phx-click=change_currency][phx-value-currency=gbp]")
    |> render_click()

    html = render(view)

    assert html =~
             "A checkout is in progress in your current currency. Try again in a few minutes."

    refute html =~ "Could not update currency"
  end

  defp payment(user, factory, attendee_email, attrs) do
    insert(
      factory,
      Keyword.merge(
        [
          host_user_id: user.id,
          host_email: user.email,
          stripe_account_id: "acct_LEDGER",
          attendee_email: attendee_email
        ],
        attrs
      )
    )
  end
end

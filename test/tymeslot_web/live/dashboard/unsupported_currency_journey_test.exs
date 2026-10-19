defmodule TymeslotWeb.Dashboard.UnsupportedCurrencyJourneyTest do
  @moduledoc """
  A host whose Connect account was opened before the currency allowlist was
  enforced, in a currency it does not hold.

  Romanian lei count in hundredths, as stored prices do, so bookings are
  still charged; the host keeps editing meeting types, but sets no price
  until they choose a supported currency, and both the editor and the
  payments page say so. Yen do not, so that host takes no payments at all,
  and the payments page says that instead of "ready".
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :payments
  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  @locked "Prices can no longer be set in your Stripe account&#39;s currency, RON"
  @switch_clears "Switching to a supported currency clears it"

  setup :setup_dashboard_user

  setup do
    with_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    :ok
  end

  # Inserted directly: the changeset would refuse the currency now.
  defp legacy_account(user, currency) do
    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_legacy_#{currency}",
      default_currency: currency,
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )
  end

  test "a two-decimal legacy host keeps their prices, cannot change them, and is told how to",
       %{conn: conn, user: user} do
    legacy_account(user, "ron")

    paid =
      insert(:meeting_type,
        user: user,
        name: "Paid call",
        payment_required: true,
        price_cents: 15_000
      )

    # The card shows the price in lei, not in the fallback currency.
    {:ok, settings, _html} = live(conn, ~p"/dashboard/meeting-settings")
    assert render(settings) =~ "RON 150.00"
    refute render(settings) =~ "€150.00"

    # The editor shows the stored price, the toggle locked, and why.
    view = open_editor(conn, paid)

    assert has_element?(view, "input#payment-required-toggle[disabled]")
    refute has_element?(view, "input[name='meeting_type[price_input]']")
    assert render(view) =~ @locked
    assert render(view) =~ "The current price is RON 150.00. #{@switch_clears}"

    # Saving another field keeps the paid price as it was.
    view
    |> element("input[name='meeting_type[name]']")
    |> render_change(%{"meeting_type" => %{"name" => "Paid call, renamed"}})

    saved = MeetingTypes.get_meeting_type(paid.id, user.id)
    assert saved.name == "Paid call, renamed"
    assert {saved.payment_required, saved.price_cents} == {true, 15_000}

    # The payments page: still ready to charge, with the editing warning.
    {:ok, payments, _html} = live(conn, ~p"/dashboard/integrations?tab=payments")
    assert render(payments) =~ "Connected and ready"
    assert render(payments) =~ "Bookings are still charged their current prices"

    payments
    |> element("button[phx-click=change_currency][phx-value-currency=eur]")
    |> render_click()

    refute render(payments) =~ "Bookings are still charged their current prices"

    # In a supported currency the old price is gone and a new one can be set.
    assert MeetingTypes.get_meeting_type(paid.id, user.id).price_cents == nil

    view = open_editor(conn, paid)

    refute render(view) =~ @locked
    refute has_element?(view, "input#payment-required-toggle[disabled]")

    view
    |> element("input#payment-required-toggle")
    |> render_click()

    assert render(view) =~ "Price (EUR)"
  end

  test "a zero-decimal legacy host is shown as unable to take payments",
       %{conn: conn, user: user} do
    legacy_account(user, "jpy")
    free = insert(:meeting_type, user: user, name: "Intro call")

    {:ok, payments, _html} = live(conn, ~p"/dashboard/integrations?tab=payments")
    html = render(payments)

    assert html =~ "Currency not supported"
    assert html =~ "Payments cannot be taken in your account&#39;s currency, JPY."
    refute html =~ "Connected and ready"

    view = open_editor(conn, free)

    assert has_element?(view, "input#payment-required-toggle[disabled]")
    assert render(view) =~ "JPY, is not supported for meeting payments"
  end

  defp open_editor(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end
end

defmodule TymeslotWeb.Dashboard.MeetingTypeUnsellableWarningTest do
  @moduledoc """
  The meeting types list tells a host when their booking page is leaving a
  paid type out because they cannot take payments right now
  (`Tymeslot.MeetingTypes.PaymentAccess`), so they learn it here rather than
  from a guest. A free type, and a paid type of a host who can take
  payments, carry no warning.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :payments
  @moduletag :live

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  setup %{user: user} do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    paid =
      insert(:meeting_type,
        user: user,
        name: "Paid Consult",
        payment_required: true,
        price_cents: 5000
      )

    free = insert(:meeting_type, user: user, name: "Free Call")

    %{paid: paid, free: free}
  end

  defp warning(type_id),
    do: "[data-meeting-type-id='#{type_id}'] [data-testid='paid-type-unsellable-notice']"

  test "warns on the paid type while the host cannot take payments",
       %{conn: conn, user: user, paid: paid, free: free} do
    insert(:connect_account, user: user, default_currency: "eur", charges_enabled: false)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    assert view |> element(warning(paid.id)) |> render() =~
             "Not offered to guests until payments are reconnected"

    refute has_element?(view, warning(free.id))
  end

  test "carries no warning once the host can take payments",
       %{conn: conn, user: user, paid: paid} do
    insert(:connect_account, user: user, default_currency: "eur", charges_enabled: true)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    assert has_element?(view, "[data-meeting-type-id='#{paid.id}']")
    refute has_element?(view, warning(paid.id))
  end
end

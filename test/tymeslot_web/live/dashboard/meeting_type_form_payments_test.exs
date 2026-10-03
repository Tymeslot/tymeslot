defmodule TymeslotWeb.Dashboard.MeetingTypeFormPaymentsTest do
  @moduledoc """
  LiveView coverage for the meeting-type form's Payments section — the
  user journey where a host marks a meeting type as paid and sets a price.

  Gating mirrors the payments dashboard: the section only becomes active
  when the `:meeting_payments` feature is enabled AND the host's Stripe
  Connect account can accept charges. When the feature is off the section
  is absent; when it is on without a charge-ready account the toggle is
  disabled with a link to connect Stripe.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :payments
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  setup do
    # Force the Core default checker so the runtime feature flag drives
    # access regardless of any SaaS overlay, then restore afterwards.
    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
    previous_flag = Application.get_env(:tymeslot, :meeting_payments_enabled)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    on_exit(fn ->
      restore_env(:feature_access_checker, previous_checker)
      restore_env(:meeting_payments_enabled, previous_flag)
    end)

    :ok
  end

  describe "Payments section gating" do
    test "is hidden when the meeting payments feature is disabled", %{conn: conn, user: user} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)

      view = open_editor(conn, insert(:meeting_type, user: user))

      refute render(view) =~ "Require payment for this meeting type"
    end

    test "shows a disabled toggle with a connect link when Stripe is not connected",
         %{conn: conn, user: user} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)

      view = open_editor(conn, insert(:meeting_type, user: user))

      html = render(view)
      assert html =~ "Require payment for this meeting type"
      assert html =~ "/dashboard/integrations?tab=payments"
      # The checkbox is disabled until Stripe charges are enabled.
      assert html =~ ~r/<input[^>]*type="checkbox"[^>]*disabled/
    end
  end

  describe "Marking a meeting type as paid" do
    setup %{user: user} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      insert(:connect_account, user: user, charges_enabled: true, default_currency: "usd")
      :ok
    end

    test "entering a price persists payment_required and price_cents",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Paid Strategy Call")
      view = open_editor(conn, meeting_type)

      # Enable payments: the toggle flips socket state so the price input
      # renders.
      view
      |> element("input[phx-click='toggle_payment_required']")
      |> render_click()

      assert render(view) =~ "Price (USD)"

      # Entering the price through the visible input auto-saves the type.
      view
      |> element("input[phx-change='change_payment_price']")
      |> render_change(%{"meeting_type" => %{"price_input" => "25.00"}})

      saved = MeetingTypes.get_meeting_type(meeting_type.id, user.id)

      assert saved.payment_required == true
      assert saved.price_cents == 2500
    end

    test "a below-minimum price is not persisted",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, name: "Too Cheap")
      view = open_editor(conn, meeting_type)

      view
      |> element("input[phx-click='toggle_payment_required']")
      |> render_click()

      view
      |> element("input[phx-change='change_payment_price']")
      |> render_change(%{"meeting_type" => %{"price_input" => "0.10"}})

      saved = MeetingTypes.get_meeting_type(meeting_type.id, user.id)

      refute saved.payment_required
      assert is_nil(saved.price_cents)
      refute render(view) =~ "All changes saved"
    end
  end

  describe "Editing a paid meeting type" do
    setup %{user: user} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      insert(:connect_account, user: user, charges_enabled: true, default_currency: "usd")
      :ok
    end

    test "pre-fills the price from the stored price_cents", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Existing Paid",
          payment_required: true,
          price_cents: 4200
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Require payment for this meeting type"
      # 4200 cents pre-fills as a 42.00 major-unit value.
      assert html =~ "42.00"
    end
  end

  # Payments sit on the Booking Rules tab, which only exists once the meeting
  # type does.
  defp open_editor(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)
end

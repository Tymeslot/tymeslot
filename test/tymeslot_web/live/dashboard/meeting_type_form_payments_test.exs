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
    test "is hidden when the meeting payments feature is disabled", %{conn: conn} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      refute render(view) =~ "Require payment for this meeting type"
    end

    test "shows a disabled toggle with a connect link when Stripe is not connected",
         %{conn: conn} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

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

    test "submitting a price persists payment_required and price_cents",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()

      # Remove the default reminder so the hidden reminder inputs do not
      # break Plug.Conn.Query re-encoding on submit (same workaround the
      # happy-path create test uses).
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      # Enable payments — the toggle flips socket state so the price input
      # renders and the hidden payment fields post on submit.
      view
      |> element("input[phx-click='toggle_payment_required']")
      |> render_click()

      html = render(view)
      assert html =~ "Price (USD)"

      # Enter the price through the visible input's phx-change so the socket
      # (and the mirrored hidden `meeting_type[price]` input) carry the value.
      view
      |> element("input[phx-change='change_payment_price']")
      |> render_change(%{"meeting_type" => %{"price_input" => "25.00"}})

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{
          "name" => "Paid Strategy Call",
          "duration" => "30"
        }
      })
      |> render_submit()

      assert render(view) =~ "Meeting type created"

      created =
        Enum.find(
          MeetingTypes.get_all_meeting_types(user.id),
          &(&1.name == "Paid Strategy Call")
        )

      assert created.payment_required == true
      assert created.price_cents == 2500
    end

    test "a below-minimum price surfaces a changeset error and does not persist",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
      view |> element("button", "Add Meeting Type") |> render_click()
      view |> element("button[aria-label='Remove reminder']") |> render_click()

      view
      |> element("input[phx-click='toggle_payment_required']")
      |> render_click()

      view
      |> element("input[phx-change='change_payment_price']")
      |> render_change(%{"meeting_type" => %{"price_input" => "0.10"}})

      view
      |> form("form[phx-submit='save_meeting_type']", %{
        "meeting_type" => %{
          "name" => "Too Cheap",
          "duration" => "30"
        }
      })
      |> render_submit()

      html = render(view)
      refute html =~ "Meeting type created"
      assert html =~ "must be at least USD 0.50"

      refute Enum.any?(
               MeetingTypes.get_all_meeting_types(user.id),
               &(&1.name == "Too Cheap")
             )
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

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)
end

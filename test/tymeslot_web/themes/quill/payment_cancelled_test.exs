defmodule TymeslotWeb.Themes.Quill.PaymentCancelledTest do
  @moduledoc """
  Covers the Quill `payment-cancelled` return page reached after the
  attendee aborts Stripe Checkout. Unlike `payment-processing`, this
  page does not require a session_id match — the attendee may arrive
  here at any point in the flow — but it still verifies the host's
  configured theme matches the URL slug.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  setup do
    user = insert(:user)
    {:ok, profile} = Tymeslot.Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Tymeslot.Profiles.update_profile(profile, %{booking_theme: "1"})
    %{user: user}
  end

  test "renders the cancellation copy", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

    assert html =~ "Payment cancelled"
  end

  test "redirects to / when meeting belongs to a different theme", %{conn: conn, user: user} do
    {:ok, profile} = Tymeslot.Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Tymeslot.Profiles.update_profile(profile, %{booking_theme: "2"})

    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")
  end
end

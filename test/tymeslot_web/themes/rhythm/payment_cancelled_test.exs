defmodule TymeslotWeb.Themes.Rhythm.PaymentCancelledTest do
  @moduledoc """
  Mirrors the Quill cancellation-page contract for Rhythm.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Profiles

  setup do
    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{booking_theme: "2"})
    %{user: user}
  end

  test "renders the cancellation copy", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    {:ok, _view, html} =
      live(conn, ~p"/themes/rhythm/payment-cancelled/#{meeting.id}")

    assert html =~ "Payment cancelled"
  end

  test "offers a rebook link to the meeting type's booking page", %{conn: conn, user: user} do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{username: "rhythmhost"})

    meeting_type = insert(:meeting_type, user: user, name: "Paid Consultation")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        status: "awaiting_payment"
      )

    {:ok, _view, html} =
      live(conn, ~p"/themes/rhythm/payment-cancelled/#{meeting.id}")

    assert html =~ ~s(href="/rhythmhost/paid-consultation")
    assert html =~ "Return to booking"
  end

  test "rebook link uses the custom slug when the meeting type has one set", %{
    conn: conn,
    user: user
  } do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{username: "rhythmhost"})

    # The name-derived slug would be "paid-consultation"; the custom slug
    # overrides it in the rebook path.
    meeting_type =
      insert(:meeting_type, user: user, name: "Paid Consultation", slug: "vip-consult")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        status: "awaiting_payment"
      )

    {:ok, _view, html} =
      live(conn, ~p"/themes/rhythm/payment-cancelled/#{meeting.id}")

    assert html =~ ~s(href="/rhythmhost/vip-consult"), "rebook link must use the custom slug"

    refute html =~ ~s(href="/rhythmhost/paid-consultation"),
           "rebook link must NOT use the stale name-derived slug"

    assert html =~ "Return to booking"
  end

  test "redirects to / when meeting belongs to a different theme", %{conn: conn, user: user} do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{booking_theme: "1"})

    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/themes/rhythm/payment-cancelled/#{meeting.id}")
  end

  test "dead render does not load page data", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    ref = make_ref()
    parent = self()
    handler_id = "rhythm-payment-cancelled-dead-render-#{inspect(ref)}"
    data_sources = ~w(meetings booking_payments)

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source in data_sources, do: send(parent, {:db_query, ref, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    get(conn, ~p"/themes/rhythm/payment-cancelled/#{meeting.id}")

    refute_received {:db_query, ^ref, _source}, "Data-loading query fired during dead render"
  end
end

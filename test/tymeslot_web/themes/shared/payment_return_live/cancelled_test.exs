defmodule TymeslotWeb.Themes.Shared.PaymentReturnLive.CancelledTest do
  @moduledoc """
  Covers the payment-cancelled return page (shared by every theme; driven
  here under the Quill slug). Unlike `payment-processing`, this page does
  not require a session_id match — the attendee may arrive here at any
  point in the flow — but it still verifies the host's configured theme
  matches the URL slug.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Mox
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.BookingTestHelpers
  alias Tymeslot.Invitations
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.FailAndExpire
  alias Tymeslot.Profiles
  alias Tymeslot.SignedToken

  # The guest's mount expires their checkout from a task the LiveView starts.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_booking_theme(profile, "1")
    %{user: user}
  end

  test "renders the cancellation copy", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

    assert html =~ "Payment cancelled"
  end

  test "offers a rebook link to the meeting type's booking page", %{conn: conn, user: user} do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.change_username(profile, "hosttester")

    meeting_type = insert(:meeting_type, user: user, name: "Paid Consultation")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        status: :awaiting_payment
      )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

    assert html =~ ~s(href="/hosttester/paid-consultation")
    assert html =~ "Return to booking"
  end

  test "rebook link uses the custom slug when the meeting type has one set", %{
    conn: conn,
    user: user
  } do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.change_username(profile, "hosttester")

    # The name-derived slug would be "paid-consultation"; the custom slug
    # overrides it in the rebook path.
    meeting_type =
      insert(:meeting_type, user: user, name: "Paid Consultation", slug: "vip-consult")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        status: :awaiting_payment
      )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

    assert html =~ ~s(href="/hosttester/vip-consult"), "rebook link must use the custom slug"

    refute html =~ ~s(href="/hosttester/paid-consultation"),
           "rebook link must NOT use the stale name-derived slug"

    assert html =~ "Return to booking"
  end

  describe "a booking made through an invitation" do
    setup do
      %{user: user} = BookingTestHelpers.seed_booking_account("1", "invitehost", "Etc/UTC")

      type =
        insert(:meeting_type,
          user: user,
          name: "Coaching",
          slug: "coaching",
          duration_minutes: 30,
          is_active: true,
          invitation_only: true
        )

      {:ok, invitation} = Invitations.create(user.id, type, %{})

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_id: type.id,
          invitation_id: invitation.id,
          status: :awaiting_payment
        )

      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        status: :pending,
        stripe_account_id: "acct_TEST",
        stripe_checkout_session_id: "cs_TEST"
      )

      %{invitation: invitation, meeting: meeting}
    end

    test "the guest is told the invitation is held, their checkout is ended, then the way back has it",
         %{conn: conn, invitation: invitation, meeting: meeting} do
      test_pid = self()

      expect(StripeAdapterMock, :expire_checkout_session, fn "cs_TEST", opts ->
        send(test_pid, {:expired_session, opts[:connect_account]})
        {:ok, %{id: "cs_TEST", status: "expired"}}
      end)

      {:ok, view, html} = live(conn, guest_path(meeting))

      # The booking page would refuse the invitation as used while this
      # meeting holds it, so there is no link to it yet.
      assert html =~ ~s(data-testid="payment-invitation-held")
      refute html =~ "Return to booking"

      # Leaving the checkout ends it at Stripe rather than at its timeout.
      assert_receive {:expired_session, "acct_TEST"}

      # Stripe's `checkout.session.expired` webhook releases the hold.
      expire_checkout(meeting)

      html = render(view)
      refute html =~ ~s(data-testid="payment-invitation-held")

      [href] =
        html
        |> Floki.parse_document!()
        |> Floki.find("a.payment-page-link")
        |> Floki.attribute("href")

      assert %URI{path: "/invitehost/coaching", query: query} = URI.parse(href)
      assert URI.decode_query(query) == %{"invite" => invitation.token}

      # The link opens the type's times: the entry gate lets the guest in.
      {:ok, booking, _html} = live(build_conn(), href <> "&timezone=Etc/UTC")
      assert has_element?(booking, "[data-fact='date']")
    end

    test "offers the guest the way back with the invitation once the hold has ended", %{
      conn: conn,
      invitation: invitation,
      meeting: meeting
    } do
      expire_checkout(meeting)

      {:ok, _view, html} = live(conn, guest_path(meeting))

      assert html =~ "Return to booking"
      token = URI.encode_www_form(invitation.token)
      assert html =~ ~s(href="/invitehost/coaching?invite=#{token}")
    end

    test "the language switch keeps the guest's proof", %{conn: conn, meeting: meeting} do
      stub(StripeAdapterMock, :expire_checkout_session, fn _id, _opts -> {:ok, %{}} end)
      {:ok, view, _html} = live(conn, guest_path(meeting))

      render_hook(view, "change_locale", %{"locale" => "de"})
      {path, _flash} = assert_redirect(view)

      query = URI.decode_query(URI.parse(path).query)
      assert query["locale"] == "de"
      assert MeetingPayments.returned_from_checkout?(meeting.id, query["return_token"])
    end

    # Anyone else holding the meeting id (a shared screen, a log line, a
    # forwarded address) must not learn the token.
    for {label, proof} <- [
          {"no proof", :none},
          {"a proof for another meeting", :other_meeting},
          {"a tampered proof", :tampered}
        ] do
      test "with #{label}, the page never shows the token and leaves the checkout alone", %{
        conn: conn,
        invitation: invitation,
        meeting: meeting
      } do
        path =
          ~p"/themes/quill/payment-cancelled/#{meeting.id}" <>
            proof_query(unquote(proof), meeting)

        {:ok, view, html} = live(conn, path)
        refute html =~ invitation.token
        assert html =~ ~s(data-testid="payment-invitation-withheld")
        refute html =~ "Return to booking"

        # Not even once the hold has ended.
        expire_checkout(meeting)
        html = render(view)
        refute html =~ invitation.token
        refute html =~ URI.encode_www_form(invitation.token)
        assert html =~ ~s(data-testid="payment-invitation-withheld")
      end
    end
  end

  defp proof_query(:none, _meeting), do: ""

  defp proof_query(:other_meeting, _meeting),
    do: "?return_token=" <> SignedToken.sign(:checkout_return, UUID.generate())

  defp proof_query(:tampered, meeting),
    do: "?return_token=" <> SignedToken.sign(:checkout_return, meeting.id) <> "x"

  defp guest_path(meeting),
    do:
      ~p"/themes/quill/payment-cancelled/#{meeting.id}?#{%{return_token: SignedToken.sign(:checkout_return, meeting.id)}}"

  # The real webhook path for a checkout that lapsed: expires the meeting and
  # broadcasts `:expired` on its payment topic.
  defp expire_checkout(meeting) do
    assert :ok =
             FailAndExpire.handle(
               %{
                 "id" => "evt_expired_#{System.unique_integer([:positive])}",
                 "account" => "acct_TEST",
                 "data" => %{
                   "object" => %{"id" => "cs_TEST", "client_reference_id" => meeting.id}
                 }
               },
               "checkout.session.expired",
               :webhook_expired
             )
  end

  test "redirects to / when meeting belongs to a different theme", %{conn: conn, user: user} do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_booking_theme(profile, "2")

    meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")
  end

  # The dead render reads the meeting and its organiser for the page's
  # language alone (`PaymentReturn.assign_dead_render_language/3`); the
  # payment is the connected mount's, once the visitor is authorised.
  test "dead render does not load the payment", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: :awaiting_payment)

    ref = make_ref()
    parent = self()
    handler_id = "quill-payment-cancelled-dead-render-#{inspect(ref)}"
    data_sources = ~w(booking_payments)

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source in data_sources, do: send(parent, {:db_query, ref, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    get(conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

    refute_received {:db_query, ^ref, _source}, "Data-loading query fired during dead render"
  end
end

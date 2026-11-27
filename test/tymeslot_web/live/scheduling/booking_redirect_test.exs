defmodule TymeslotWeb.Live.Scheduling.BookingRedirectTest do
  @moduledoc """
  A meeting type's redirect after booking, walked on the public booking page.

  A new booking that reaches the confirmation sends a booker on a page of its
  own to the meeting type's `redirect_url`, with the booking's details when
  the host opted in (`redirect_pass_details`). In an embed the page never
  navigates itself: it always pushes `"booking_success"` to the embedding
  page, with the address or nil, which is the contract with the `BookingSuccess`
  hook. Covered here: both modes, with and without details, the UTM tags of
  the landing URL (also with booking analytics off), custom answers, an
  approval type, a paid booking (embedded and back from Stripe Checkout),
  and the bookings that must not redirect: a reschedule and an owner's
  preview, which runs inside the dashboard.

  Every address is checked for the meeting's `uid`, the bearer secret behind
  the cancel and reschedule links.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [await: 2, seed_organiser: 3]

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  @attendee_form "form[data-fact='attendee']:not([data-alternate])"
  @thanks "https://example.com/thanks"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    :ok
  end

  describe "a booking page on its own" do
    @tag :capture_log
    test "sends the booker to the address as saved, without details", %{conn: conn} do
      %{profile: profile} = seed("redir-plain", redirect_url: "#{@thanks}?from=tymeslot")

      view = open(conn, profile)
      book(view)

      assert {url, _flash} = assert_redirect(view, 5_000)
      assert url == "#{@thanks}?from=tymeslot"
    end

    @tag :capture_log
    test "appends the booking's details when the host opted in", %{conn: conn} do
      %{profile: profile, meeting_types: [type]} =
        seed("redir-details", redirect_url: @thanks, redirect_pass_details: true)

      view = open(conn, profile)
      book(view, %{"name" => "Ada Lovelace", "email" => "ada@example.com"})

      {url, _flash} = assert_redirect(view, 5_000)
      [meeting] = meetings_of(type)

      assert String.starts_with?(url, @thanks <> "?")
      query = query(url)

      assert query["event_type_name"] == "Discovery Call"
      assert query["event_type_uuid"] == to_string(type.id)
      assert query["invitee_email"] == "ada@example.com"
      assert query["invitee_full_name"] == "Ada Lovelace"
      assert query["invitee_first_name"] == "Ada"
      assert query["invitee_last_name"] == "Lovelace"
      assert query["invitee_uuid"] == meeting.calendar_uid
      assert_same_instant(query["event_start_time"], meeting.start_time)
      assert query["assigned_to"] == meeting.organizer_name
      refute url =~ meeting.uid
    end

    @tag :capture_log
    test "passes the landing URL's UTM tags with booking analytics off", %{conn: conn} do
      Application.put_env(:tymeslot, :booking_analytics_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :booking_analytics_enabled, true) end)

      %{profile: profile, meeting_types: [type]} =
        seed("redir-utm", redirect_url: @thanks, redirect_pass_details: true)

      view =
        open(conn, profile, %{
          "utm_source" => "linkedin",
          "utm_medium" => "social",
          "utm_campaign" => "spring"
        })

      book(view)

      {url, _flash} = assert_redirect(view, 5_000)
      query = query(url)

      assert query["utm_source"] == "linkedin"
      assert query["utm_medium"] == "social"
      assert query["utm_campaign"] == "spring"
      refute Map.has_key?(query, "utm_term")

      # Nothing of it is persisted while analytics is off.
      [meeting] = meetings_of(type)
      assert meeting.utm_source == nil
    end

    @tag :capture_log
    test "passes the custom questions' answers", %{conn: conn} do
      %{profile: profile} =
        seed("redir-answers",
          redirect_url: @thanks,
          redirect_pass_details: true,
          custom_fields: [
            %{"id" => "rq-company", "type" => "short_text", "label" => "Company", "position" => 0}
          ]
        )

      view = open(conn, profile)
      book(view, %{}, answers: %{"rq-company" => "Acme Ltd"})

      {url, _flash} = assert_redirect(view, 5_000)
      assert query(url)["answer_1"] == "Acme Ltd"
    end

    @tag :capture_log
    test "redirects a booking held for the host's approval too", %{conn: conn} do
      %{profile: profile, meeting_types: [type]} =
        seed("redir-approval", redirect_url: @thanks, requires_approval: true)

      view = open(conn, profile)
      book(view)

      assert {@thanks, _flash} = assert_redirect(view, 5_000)
      assert [%{status: :awaiting_approval}] = meetings_of(type)
    end

    # The confirmation is where the booker is told to check their inbox and
    # can have the link sent again; the booking counts only once confirmed.
    @tag :capture_log
    test "does not redirect a booking still awaiting email confirmation", %{conn: conn} do
      %{profile: profile, meeting_types: [type]} =
        seed("redir-verify",
          redirect_url: @thanks,
          redirect_pass_details: true,
          requires_email_verification: true
        )

      view = open(conn, profile)
      book(view)

      await(view, "[data-testid='check-inbox']")
      assert has_element?(view, "[data-testid='resend-verification']")
      assert_no_redirect(view)
      assert [%{status: :awaiting_verification}] = meetings_of(type)
    end

    @tag :capture_log
    test "stays on the confirmation without a redirect address", %{conn: conn} do
      %{profile: profile} = seed("redir-none", redirect_url: nil, redirect_pass_details: true)

      view = open(conn, profile)
      book(view)

      await(view, "[data-testid='confirmation-heading']")
    end

    @tag :capture_log
    test "does not redirect a reschedule", %{conn: conn} do
      %{user: user, profile: profile, meeting_types: [type]} =
        seed("redir-resched", redirect_url: @thanks, redirect_pass_details: true)

      start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_name: "Host",
          meeting_type_id: type.id,
          attendee_name: "Test Attendee",
          attendee_email: "attendee@example.com",
          attendee_timezone: "UTC",
          start_time: start,
          end_time: DateTime.add(start, 30, :minute),
          duration: 30,
          status: :confirmed
        )

      view = open(conn, profile, %{"reschedule_meeting_uid" => meeting.uid})
      book(view, %{"name" => "Test Attendee", "email" => "attendee@example.com"})

      await(view, "[data-testid='confirmation-heading']")
      assert_no_redirect(view)
      assert [_moved] = meetings_of(type)
    end

    @tag :capture_log
    test "does not redirect an owner's preview", %{conn: conn} do
      %{user: user, profile: profile} =
        seed("redir-preview", redirect_url: @thanks, redirect_pass_details: true)

      view =
        open(conn, profile, %{"preview" => "true", "preview_token" => PreviewToken.sign(user.id)})

      book(view)

      await(view, "[data-testid='confirmation-heading']")
      assert_no_redirect(view)
      assert Repo.aggregate(MeetingSchema, :count, :id) == 0
    end
  end

  describe "an embedded booking page" do
    @tag :capture_log
    test "pushes booking_success with the address and the details, never redirecting",
         %{conn: conn} do
      %{profile: profile, meeting_types: [type]} =
        seed("redir-embed", [redirect_url: @thanks, redirect_pass_details: true], embed: true)

      view = open_embedded(conn, profile, %{"utm_source" => "newsletter"})
      book(view, %{"name" => "Ada Lovelace", "email" => "ada@example.com"})

      assert_push_event(view, "booking_success", %{redirect_url: url, data: data}, 5_000)
      [meeting] = meetings_of(type)

      assert String.starts_with?(url, @thanks <> "?")
      assert query(url)["utm_source"] == "newsletter"

      assert data.eventTypeName == "Discovery Call"
      assert data.eventTypeUuid == to_string(type.id)
      assert_same_instant(data.eventStartTime, meeting.start_time)
      assert data.appointmentId == meeting.calendar_uid
      assert data.inviteeUuid == meeting.calendar_uid
      assert data.inviteeEmail == "ada@example.com"
      assert data.inviteeFirstName == "Ada"
      assert data.utmSource == "newsletter"
      refute url =~ meeting.uid
      refute inspect(data) =~ meeting.uid

      assert_no_redirect(view)
    end

    @tag :capture_log
    test "pushes booking_success without an address, and nothing personal without the opt-in",
         %{conn: conn} do
      %{profile: profile} = seed("redir-embed-none", [redirect_url: nil], embed: true)

      view = open_embedded(conn, profile)
      book(view)

      assert_push_event(view, "booking_success", %{redirect_url: nil, data: data}, 5_000)
      assert data.eventTypeName == "Discovery Call"
      refute Map.has_key?(data, :inviteeEmail)
      refute Map.has_key?(data, :inviteeFullName)
      refute Map.has_key?(data, :appointmentId)
    end

    @tag :capture_log
    test "pushes nothing while the booking awaits email confirmation", %{conn: conn} do
      %{profile: profile} =
        seed(
          "redir-embed-verify",
          [redirect_url: @thanks, redirect_pass_details: true, requires_email_verification: true],
          embed: true
        )

      view = open_embedded(conn, profile)
      book(view)

      await(view, "[data-testid='check-inbox']")
      refute_push_event(view, "booking_success", _payload, 200)
      assert_no_redirect(view)
    end

    @tag :capture_log
    test "an owner's preview pushes nothing, so the dashboard is never navigated",
         %{conn: conn} do
      %{user: user, profile: profile} =
        seed("redir-embed-preview", [redirect_url: @thanks, redirect_pass_details: true],
          embed: true
        )

      view =
        open_embedded(conn, profile, %{
          "preview" => "true",
          "preview_token" => PreviewToken.sign(user.id)
        })

      book(view)

      await(view, "[data-testid='confirmation-heading']")
      refute_push_event(view, "booking_success", _payload, 200)
      assert_no_redirect(view)
    end
  end

  describe "a paid booking" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true,
        payment_application_fee_bp: 50
      )

      stub(CalendarMock, :get_booking_integration_info, fn _user_id ->
        {:error, :no_integration}
      end)

      :ok
    end

    @tag :capture_log
    test "embedded, pushes booking_success once the payment's :paid arrives", %{conn: conn} do
      %{profile: profile} =
        seed_paid("redir-paid-embed", embed: true)

      StripeStub.expect(
        :create_checkout_session,
        1,
        StripeStubResponses.checkout_session("cs_redir", "https://checkout.stripe.com/cs_redir")
      )

      view = open_embedded(conn, profile)
      book(view, %{"name" => "Pay Pat", "email" => "pat@example.com"})
      _drain = :sys.get_state(view.pid)

      meeting = :sys.get_state(view.pid).socket.assigns.awaiting_payment_meeting
      refute_push_event(view, "booking_success", _payload, 50)

      Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting.id}", :paid)

      assert_push_event(view, "booking_success", %{redirect_url: url, data: data}, 5_000)
      assert query(url)["invitee_email"] == "pat@example.com"
      assert data.inviteeFullName == "Pay Pat"
      refute url =~ meeting.uid
    end

    # The iframe tells the embedding page, which navigates; the Stripe tab it
    # opened lands on the processing page and must not redirect as well.
    @tag :capture_log
    test "embedded, the Stripe tab's processing page does not redirect too", %{conn: conn} do
      %{profile: profile} = seed_paid("redir-paid-embed-tab", embed: true)

      StripeStub.expect(
        :create_checkout_session,
        1,
        StripeStubResponses.checkout_session(
          "cs_redir_e",
          "https://checkout.stripe.com/cs_redir_e"
        )
      )

      view = open_embedded(conn, profile)
      book(view, %{"name" => "Pay Pat", "email" => "pat@example.com"})
      _drain = :sys.get_state(view.pid)

      [%{form: form}] = StripeStub.requests(:create_checkout_session)
      assert form["success_url"] =~ "?session_id={CHECKOUT_SESSION_ID}&from_embed=1"

      {:ok, page, _html} = live(conn, success_path(form, "cs_redir_e"))
      meeting_id = :sys.get_state(page.pid).socket.assigns.meeting.id

      complete_checkout(meeting_id, "cs_redir_e")

      # The iframe still hears of the payment and tells the embedding page.
      assert_push_event(view, "booking_success", %{redirect_url: url}, 5_000)
      assert String.starts_with?(url, @thanks)

      _drain = :sys.get_state(page.pid)
      assert Repo.get!(MeetingSchema, meeting_id).status == :confirmed
      assert_no_redirect(page)
      assert render(page) =~ "Booking confirmed"
    end

    @tag :capture_log
    test "back from Stripe Checkout, the processing page redirects once the booking stands",
         %{conn: conn} do
      %{profile: profile} = seed_paid("redir-paid-top")

      StripeStub.expect(:create_checkout_session, 1, fn _request ->
        StripeFixtures.object("checkout_session_payment", %{
          "id" => "cs_redir_top",
          "url" => "https://checkout.stripe.com/cs_redir_top"
        })
      end)

      view = open(conn, profile)
      book(view, %{"name" => "Pay Pat", "email" => "pat@example.com"})
      assert_redirect(view, "https://checkout.stripe.com/cs_redir_top", 5_000)

      [%{form: form}] = StripeStub.requests(:create_checkout_session)
      refute form["success_url"] =~ "from_embed"

      {:ok, page, _html} = live(conn, success_path(form, "cs_redir_top"))
      meeting_id = :sys.get_state(page.pid).socket.assigns.meeting.id

      complete_checkout(meeting_id, "cs_redir_top")

      {url, _flash} = assert_redirect(page, 5_000)
      meeting = Repo.get!(MeetingSchema, meeting_id)

      assert meeting.status == :confirmed
      assert query(url)["invitee_email"] == "pat@example.com"
      assert query(url)["invitee_uuid"] == meeting.calendar_uid
      refute url =~ meeting.uid
    end

    @tag :capture_log
    test "the processing page stays put while the payment is outstanding", %{conn: conn} do
      %{profile: profile} = seed_paid("redir-paid-wait")

      StripeStub.expect(
        :create_checkout_session,
        1,
        StripeStubResponses.checkout_session(
          "cs_redir_w",
          "https://checkout.stripe.com/cs_redir_w"
        )
      )

      view = open(conn, profile)
      book(view, %{"name" => "Pay Pat", "email" => "pat@example.com"})
      assert_redirect(view, "https://checkout.stripe.com/cs_redir_w", 5_000)

      [%{form: form}] = StripeStub.requests(:create_checkout_session)

      {:ok, page, _html} = live(conn, success_path(form, "cs_redir_w"))
      assert render(page) =~ "Confirming your payment"
      assert_no_redirect(page)
    end
  end

  # An organiser on the Quill theme with one meeting type, "Discovery Call",
  # carrying `type_attrs` (plus `:custom_fields`, see `seed_organiser/3`).
  defp seed(username, type_attrs, opts \\ []) do
    profile_attrs =
      if opts[:embed], do: [allowed_embed_domains: ["embedder.test"]], else: []

    seed_organiser("1", username,
      profile: profile_attrs,
      types: [[name: "Discovery Call", duration_minutes: 30] ++ type_attrs]
    )
  end

  defp seed_paid(username, opts \\ []) do
    %{user: user} =
      seeded =
      seed(
        username,
        [
          redirect_url: @thanks,
          redirect_pass_details: true,
          payment_required: true,
          price_cents: 5000
        ],
        opts
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_REDIR",
      default_currency: "usd",
      charges_enabled: true
    )

    seeded
  end

  defp open(conn, profile, query \\ %{}) do
    query = URI.encode_query(Map.put(query, "timezone", "UTC"))
    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")
    view
  end

  defp open_embedded(conn, profile, query \\ %{}) do
    conn = put_req_header(conn, "referer", "https://embedder.test/page")
    view = open(conn, profile, Map.put(query, "embed", "1"))

    assert :sys.get_state(view.pid).socket.assigns[:embedded] == true
    view
  end

  # Walks to the attendee form and submits it. Submitted here rather than by
  # `BookingDriver.submit/2`, which renders the page afterwards: a booking
  # that redirects has left it by then.
  defp book(view, attendee \\ %{}, opts \\ []) do
    BookingDriver.book(view, Keyword.merge([until: :attendee], opts))
    submit(view, attendee)
  end

  defp submit(view, attendee) do
    view
    |> form(@attendee_form, %{
      "booking" =>
        Map.merge(
          %{"name" => "Test Booker", "email" => "booker@example.com", "message" => ""},
          attendee
        )
    })
    |> render_submit()
  end

  # The success URL the checkout session was created with, as Stripe sends
  # the visitor back to it, as a path.
  defp success_path(form, session_id) do
    form["success_url"]
    |> String.replace("{CHECKOUT_SESSION_ID}", session_id)
    |> String.replace_prefix(Endpoint.url(), "")
  end

  # The `checkout.session.completed` webhook for `session_id`, paid in full.
  defp complete_checkout(meeting_id, session_id) do
    assert :ok =
             CheckoutSessionCompleted.handle(%{
               "id" => "evt_" <> session_id,
               "type" => "checkout.session.completed",
               "account" => "acct_REDIR",
               "created" => System.os_time(:second),
               "data" => %{
                 "object" => %{
                   "id" => session_id,
                   "client_reference_id" => meeting_id,
                   "payment_status" => "paid",
                   "amount_total" => 5000,
                   "currency" => "usd"
                 }
               }
             })
  end

  defp meetings_of(type) do
    MeetingSchema
    |> Repo.all()
    |> Enum.filter(&(&1.meeting_type_id == type.id))
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  # ISO 8601 with the invitee's offset (here UTC's, "+00:00"), naming the
  # meeting's start.
  defp assert_same_instant(iso, datetime) do
    assert iso =~ ~r/[+-]\d\d:\d\d$/
    assert {:ok, parsed, _offset} = DateTime.from_iso8601(iso)
    assert DateTime.compare(parsed, datetime) == :eq
  end

  defp assert_no_redirect(view) do
    {path, _flash} = assert_redirect(view, 50)
    flunk("expected no redirect, got one to #{path}")
  rescue
    ExUnit.AssertionError -> :ok
    ArgumentError -> :ok
  end
end

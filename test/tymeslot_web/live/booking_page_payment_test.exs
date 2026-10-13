defmodule TymeslotWeb.BookingPagePaymentTest do
  @moduledoc """
  A paid booking made through a booking page pays and returns in that page's
  look: Stripe sends the attendee back to the page's theme, the return pages
  accept that theme, and "Return to booking" leads back under the page's
  address. A booking made on `/<username>` keeps the profile's.
  """

  # async: false — the checkout case mutates the global :feature_access_checker
  # and :meeting_payments_enabled application env.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :scheduling

  import Mox
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.MeetingPayments.CheckoutSessions
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "1")
    page = insert(:booking_page, profile: profile, slug: "einfachiso", booking_theme: "2")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Paid Consultation",
        payment_required: true,
        price_cents: 5000
      )

    %{user: user, page: page, meeting_type: meeting_type}
  end

  describe "the checkout session" do
    setup do
      previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
      previous_payments = Application.get_env(:tymeslot, :meeting_payments_enabled)

      Application.put_env(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Features.DefaultAccessChecker
      )

      Application.put_env(:tymeslot, :meeting_payments_enabled, true)

      on_exit(fn ->
        Application.put_env(:tymeslot, :meeting_payments_enabled, previous_payments)
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      end)

      :ok
    end

    test "returns a page's booking to the page's theme", ctx do
      insert(:connect_account, user: ctx.user, charges_enabled: true)
      meeting = paid_meeting(ctx, booking_page_id: ctx.page.id)

      expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
        assert params.success_url =~ "/themes/rhythm/payment-processing/#{meeting.id}"
        assert params.cancel_url =~ "/themes/rhythm/payment-cancelled/#{meeting.id}"
        {:ok, %{id: "cs_PAGE", url: "https://checkout.stripe.com/cs_PAGE"}}
      end)

      assert {:ok, %{booking_payment: payment}} =
               CheckoutSessions.create_session_for_booking(meeting)

      assert payment.booking_theme_id == "2"
    end

    test "returns a booking made on the username to the profile's theme", ctx do
      insert(:connect_account, user: ctx.user, charges_enabled: true)
      meeting = paid_meeting(ctx, booking_page_id: nil)

      expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
        assert params.success_url =~ "/themes/quill/payment-processing/#{meeting.id}"
        {:ok, %{id: "cs_PROFILE", url: "https://checkout.stripe.com/cs_PROFILE"}}
      end)

      assert {:ok, %{booking_payment: %{booking_theme_id: "1"}}} =
               CheckoutSessions.create_session_for_booking(meeting)
    end
  end

  describe "the return pages" do
    test "a page's failed checkout returns in the page's theme, back to the page", ctx do
      meeting = paid_meeting(ctx, booking_page_id: ctx.page.id, status: "expired")
      failed_payment(ctx, meeting)

      {:ok, _view, html} =
        live(ctx.conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

      assert html =~ ~s(href="/einfachiso/paid-consultation")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(
                 ctx.conn,
                 ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST"
               )
    end

    test "a page's cancelled checkout returns in the page's theme, back to the page", ctx do
      meeting = paid_meeting(ctx, booking_page_id: ctx.page.id)

      {:ok, _view, html} = live(ctx.conn, ~p"/themes/rhythm/payment-cancelled/#{meeting.id}")

      assert html =~ ~s(href="/einfachiso/paid-consultation")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(ctx.conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")
    end

    test "a booking made on the username keeps the profile's theme and address", ctx do
      meeting = paid_meeting(ctx, booking_page_id: nil)

      {:ok, _view, html} = live(ctx.conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

      assert html =~ ~s(href="/joern/paid-consultation")
    end

    test "once the page is gone, the profile's theme and address return", ctx do
      meeting = paid_meeting(ctx, booking_page_id: ctx.page.id)
      {:ok, _deleted} = BookingPages.delete(ctx.page)

      {:ok, _view, html} = live(ctx.conn, ~p"/themes/quill/payment-cancelled/#{meeting.id}")

      assert html =~ ~s(href="/joern/paid-consultation")
    end
  end

  defp paid_meeting(ctx, attrs) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: ctx.user.id,
          meeting_type_ref: ctx.meeting_type,
          attendee_email: "alice@example.com",
          status: "awaiting_payment"
        ],
        attrs
      )
    )
  end

  defp failed_payment(ctx, meeting) do
    insert(:booking_payment,
      meeting: meeting,
      host_user_id: ctx.user.id,
      status: "failed",
      stripe_checkout_session_id: "cs_TEST"
    )
  end
end

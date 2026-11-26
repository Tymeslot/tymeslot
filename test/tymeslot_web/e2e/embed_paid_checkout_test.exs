defmodule TymeslotWeb.E2E.EmbedPaidCheckoutTest do
  @moduledoc """
  A paid booking made inside an embed leaves the frame for checkout.

  Stripe Checkout refuses to be framed, so a framed booker never navigates
  to it: the LiveView pushes `payment_redirect_open_tab` and the
  `PaymentRedirectOpenTab` hook opens the checkout in a new tab, while the
  frame waits on the "complete your payment" view. The LiveView half is
  covered by `EmbedPaidBookingTest`; this drives the hook in a browser, on a
  host page of another origin that frames the booking page through
  `embed.js`.

  Stripe is stubbed at HTTP level, and the checkout address the stub hands
  back is a page on the host's server, so the new tab has somewhere to land
  without the network.
  """
  use TymeslotWeb.BrowserCase, async: false

  import Ecto.Query, only: [where: 2]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.E2E.BookerSteps

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias TymeslotWeb.E2E.HostSite
  alias TymeslotWeb.Endpoint

  @moduletag :e2e
  @moduletag :payments
  @moduletag :themes

  # The booking page's LiveView is not one of the test's `$callers`.
  setup {StripeStub, :shared!}

  setup do
    # Core ships with meeting payments off; without these the paid branch
    # stops at `:payments_unavailable` before reaching Stripe.
    with_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50
    )

    :ok
  end

  feature "a paid booking in an embed opens checkout in a new tab and the frame waits",
          %{session: session} do
    {user, profile} = create_paid_profile()
    session_id = "cs_E2E_embed"

    site =
      HostSite.start!(%{
        "/" => HostSite.page(~s(<div id="tymeslot-booking" data-username="#{profile.username}"
                            data-theme="1" data-layout="column"></div>)),
        "/checkout/#{session_id}" =>
          "<!doctype html><title>Checkout</title><h1 id=\"checkout\">Pay here</h1>"
      })

    checkout_url = site <> "/checkout/#{session_id}"

    StripeStub.expect(
      :create_checkout_session,
      StripeStubResponses.checkout_session(session_id, checkout_url)
    )

    session =
      session
      |> resize_window(1280, 900)
      |> visit(site <> "/")
      |> focus_frame(css("#tymeslot-booking iframe[title='Booking Widget']"))
      |> assert_has(css("html[data-embedded]"))
      |> wait_for_live()
      |> click(css("[data-testid='duration-option']", text: "Paid Embed Consult"))
      |> pick_first_slot()
      |> assert_has(css("[data-testid='booking-form']"))
      |> fill_in(css("input[name='booking[name]']"), with: "Embed Payer")
      |> fill_in(css("input[name='booking[email]']"), with: "payer@example.com")
      |> click(css("[data-testid='submit-booking']"))
      # The frame stays on the booking page and says where the checkout went.
      |> assert_has(css("[data-testid='awaiting-payment']"))
      |> assert_has(css("[data-testid='awaiting-payment-fallback-link'][href='#{checkout_url}']"))

    assert evaluate_script(session, "return window.location.origin;") == Endpoint.url()

    session = focus_default_frame(session)
    host_window = window_handle(session)

    # The checkout opened in a tab of its own; the host page did not move.
    checkout_window =
      eventually(
        fn ->
          assert [handle] = window_handles(session) -- [host_window]
          handle
        end,
        timeout: 5_000
      )

    session
    |> focus_window(checkout_window)
    |> assert_has(css("#checkout", text: "Pay here"))
    |> tap_url(&assert(&1 == checkout_url))
    |> focus_window(host_window)
    |> tap_url(&assert(&1 == site <> "/"))

    assert [%MeetingSchema{status: :awaiting_payment}] =
             Repo.all(where(MeetingSchema, organizer_user_id: ^user.id))
  end

  defp tap_url(session, check) do
    check.(current_url(session))
    session
  end

  defp create_paid_profile do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    insert(:connect_account,
      user: user,
      default_currency: "usd",
      charges_enabled: true
    )

    insert(:meeting_type,
      user: user,
      name: "Paid Embed Consult",
      duration_minutes: 30,
      is_active: true,
      payment_required: true,
      price_cents: 5000
    )

    profile =
      user.id
      |> Profiles.get_profile()
      |> Changeset.change(allowed_embed_domains: ["127.0.0.1"])
      |> Repo.update!()

    {user, profile}
  end
end

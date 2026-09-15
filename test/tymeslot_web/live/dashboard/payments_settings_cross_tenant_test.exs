defmodule TymeslotWeb.Dashboard.PaymentsSettingsCrossTenantTest do
  @moduledoc """
  Refunding somebody else's payment.

  `MeetingPayments.get_payment/1` loads the row before anyone checks who owns
  it, so the guarantee is the component's to keep. Two separate properties hold
  it up, and each is pinned here:

    * `open_refund_modal` takes an id from the client and must compare
      `host_user_id` against the signed-in user before storing it.
    * `submit_refund` must read the payment from `@refund_modal_payment` rather
      than from params. The form posts a `payment_id` the handler deliberately
      ignores, and a refactor that "simplifies" the handler into trusting it
      would turn the ownership check above into the only thing standing between
      a crafted frame and another host's money.

  The second property is invisible from the outside when the code is correct,
  which is why it is tested by forging a foreign id into a submit whose modal is
  legitimately open: the refund must land on the payment the server chose.
  """

  use TymeslotWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @moduletag :payments
  @moduletag :cross_tenant

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Repo

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    # Force the Core default checker so the runtime feature flag is honoured
    # regardless of whether the SaaS overlay is configured, then turn payments
    # on: the component does not render at all when the tab is gated away, and
    # a forged event that reaches nothing proves nothing.
    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)
    previous_enabled = Application.get_env(:tymeslot, :meeting_payments_enabled)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    on_exit(fn ->
      if previous_checker do
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      else
        Application.delete_env(:tymeslot, :feature_access_checker)
      end

      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_enabled)
    end)

    :ok
  end

  defp onboarded_user do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    user
  end

  defp connected_host do
    user = onboarded_user()

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_#{System.unique_integer([:positive])}",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

    user
  end

  defp paid_payment_for(user, attrs \\ %{}) do
    defaults = %{host_user_id: user.id, host_email: user.email, stripe_account_id: "acct_REFUND"}
    insert(:paid_booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  defp open_payments(conn, user) do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
    view
  end

  # No rendered button carries another host's payment id, so the forged event
  # has to be pushed at the component directly, which is what a crafted client
  # frame does.
  defp push_to_component(view, event, params) do
    view |> with_target("#payments-settings") |> render_click(event, params)
  end

  defp reload(payment), do: BookingPaymentQueries.get(payment.id)

  describe "opening the refund modal" do
    test "the host's own payment opens it", %{conn: conn} do
      host = connected_host()
      mine = paid_payment_for(host)

      view = open_payments(conn, host)
      push_to_component(view, "open_refund_modal", %{"id" => mine.id})

      assert has_element?(view, "#refund-modal"),
             "the control must open, or the refusal below proves nothing"
    end

    test "another host's payment id is refused", %{conn: conn} do
      attacker = connected_host()
      victim = connected_host()
      theirs = paid_payment_for(victim, %{stripe_account_id: "acct_VICTIM"})

      view = open_payments(conn, attacker)
      push_to_component(view, "open_refund_modal", %{"id" => theirs.id})

      refute has_element?(view, "#refund-modal")
      assert reload(theirs).refunded_amount_cents == 0
      assert reload(theirs).status == "paid"
    end
  end

  describe "submitting a refund" do
    test "a foreign payment id in the form is ignored in favour of the open modal",
         %{conn: conn} do
      attacker = connected_host()
      victim = connected_host()

      mine = paid_payment_for(attacker)
      theirs = paid_payment_for(victim, %{stripe_account_id: "acct_VICTIM"})

      # Stripe is told to refund exactly one charge. Pinning the charge id here
      # is the assertion that matters: if the handler ever read `payment_id`
      # from params, this expectation would see the victim's charge instead.
      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == mine.stripe_charge_id
        {:ok, %{id: "re_full"}}
      end)

      view = open_payments(conn, attacker)
      push_to_component(view, "open_refund_modal", %{"id" => mine.id})
      assert has_element?(view, "#refund-modal")

      view
      |> form("#refund-form", %{"refund_type" => "full"})
      |> render_submit(%{"payment_id" => theirs.id})

      render_async(view, 2_000)

      assert reload(mine).refunded_amount_cents == 5000
      assert reload(theirs).refunded_amount_cents == 0
      assert reload(theirs).status == "paid"
    end

    test "a payment that changes hands while the modal is open is not refunded",
         %{conn: conn} do
      host = connected_host()
      other = connected_host()
      payment = paid_payment_for(host)

      view = open_payments(conn, host)
      push_to_component(view, "open_refund_modal", %{"id" => payment.id})
      assert has_element?(view, "#refund-modal")

      # Stripe is stubbed to succeed on purpose. Leaving it unstubbed would make
      # Mox raise inside the async task, and the refund would fail to land for
      # that reason rather than because it was refused — the test would then
      # pass against an authorization check that had been deleted.
      stub(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:ok, %{id: "re_should_not_happen"}}
      end)

      # The modal now holds a payment the host no longer owns. This is the one
      # state in which the re-check inside the async task is load-bearing: the
      # assign is stale, and only a fresh read can tell.
      Repo.update_all(
        from(p in BookingPaymentSchema, where: p.id == ^payment.id),
        set: [host_user_id: other.id]
      )

      view
      |> form("#refund-form", %{"refund_type" => "full"})
      |> render_submit()

      render_async(view, 2_000)

      assert reload(payment).refunded_amount_cents == 0
      assert reload(payment).status == "paid"
    end

    test "a submit with no modal open refunds nothing at all", %{conn: conn} do
      attacker = connected_host()
      victim = connected_host()
      theirs = paid_payment_for(victim, %{stripe_account_id: "acct_VICTIM"})

      # Stubbed to succeed, so the refund is stopped by the handler and not by a
      # missing mock. See the note in the test above.
      stub(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:ok, %{id: "re_should_not_happen"}}
      end)

      view = open_payments(conn, attacker)

      view
      |> with_target("#payments-settings")
      |> render_submit("submit_refund", %{
        "payment_id" => theirs.id,
        "refund_type" => "full"
      })

      render_async(view, 2_000)

      assert reload(theirs).refunded_amount_cents == 0
      assert reload(theirs).status == "paid"
    end
  end
end

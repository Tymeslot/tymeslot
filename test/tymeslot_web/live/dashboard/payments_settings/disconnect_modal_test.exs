defmodule TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModalTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModal

  defp render_modal(open, pending_count, outstanding \\ %{count: 0, totals: []}) do
    render_component(&DisconnectModal.disconnect_modal/1,
      open: open,
      pending_count: pending_count,
      outstanding_refunds: outstanding,
      myself: nil
    )
  end

  defp outstanding(count, totals),
    do: %{
      count: count,
      totals: Enum.map(totals, fn {c, a} -> %{currency: c, amount_cents: a} end)
    }

  describe "disconnect_modal/1" do
    test "renders nothing when closed" do
      html = render_modal(false, 0)

      refute html =~ "disconnect-modal"
      refute html =~ "Disconnect your Stripe account"
    end

    test "renders the confirmation modal with disconnect copy when open" do
      html = render_modal(true, 0)

      assert html =~ "disconnect-modal"
      assert html =~ "Disconnect your Stripe account"
      assert html =~ "phx-click=\"disconnect\""
    end

    test "shows a warning about pending bookings when the pending count is positive" do
      html = render_modal(true, 3)

      assert html =~ "3 pending"
      assert html =~ "Disconnecting will cancel"
    end

    test "omits the pending-bookings warning when there are none" do
      html = render_modal(true, 0)

      refute html =~ "awaiting payment"
    end

    # Outstanding refunds are a different set from pending bookings: money the
    # host is already holding, which the disconnect neither cancels nor
    # settles. Discovering that afterwards is too late, so the modal names the
    # count and the total before the host confirms.
    test "names the outstanding refunds and what they come to" do
      html = render_modal(true, 0, outstanding(2, [{"eur", 8400}]))

      assert html =~ "You still owe 2 refunds totalling €84.00"
      assert html =~ "refund them from your Stripe dashboard"
    end

    test "uses the singular for a single outstanding refund" do
      html = render_modal(true, 0, outstanding(1, [{"eur", 5000}]))

      assert html =~ "You still owe 1 refund totalling €50.00"
    end

    # A host who changed their default currency can owe in both, and one sum
    # across the two would be a number with no meaning.
    test "lists a total per currency" do
      html = render_modal(true, 0, outstanding(2, [{"chf", 2000}, {"eur", 8400}]))

      assert html =~ "CHF 20.00, €84.00"
    end

    test "omits the refunds warning when nothing is outstanding" do
      html = render_modal(true, 3)

      refute html =~ "You still owe"
    end
  end
end

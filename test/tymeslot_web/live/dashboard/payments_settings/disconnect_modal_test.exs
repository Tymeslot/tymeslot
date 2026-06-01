defmodule TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModalTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModal

  defp render_modal(open, pending_count) do
    render_component(&DisconnectModal.disconnect_modal/1,
      open: open,
      pending_count: pending_count,
      myself: nil
    )
  end

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
  end
end

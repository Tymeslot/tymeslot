defmodule TymeslotWeb.Dashboard.PaymentsSettings.PaymentsTableTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.PaymentsSettings.PaymentsTable

  defp payment(attrs) do
    Map.merge(
      %{
        id: 1,
        inserted_at: ~U[2026-01-15 10:00:00Z],
        attendee_email: "alice@example.com",
        meeting_type_name: "Consult",
        amount_cents: 5000,
        refunded_amount_cents: 0,
        currency: "eur",
        status: "paid",
        paid_at: DateTime.utc_now()
      },
      Map.new(attrs)
    )
  end

  defp active_account, do: %{deleted_at: nil}
  defp deleted_account, do: %{deleted_at: DateTime.utc_now()}

  defp render_table(payments, account) do
    render_component(&PaymentsTable.payments_table/1,
      payments: payments,
      account: account,
      myself: nil
    )
  end

  describe "payments_table/1" do
    test "renders an empty state when there are no payments" do
      html = render_table([], active_account())

      assert html =~ "No payments yet."
      refute html =~ "<table"
    end

    test "renders a row with the formatted amount and status label" do
      html = render_table([payment(%{})], active_account())

      assert html =~ "alice@example.com"
      assert html =~ "Consult"
      assert html =~ "€50.00"
      assert html =~ "Paid"
    end

    test "maps each payment status to its display label" do
      statuses = %{
        "paid" => "Paid",
        "partially_refunded" => "Partially refunded",
        "refunded" => "Refunded",
        "disputed" => "Disputed",
        "pending" => "Pending",
        "failed" => "Failed"
      }

      for {status, label} <- statuses do
        html = render_table([payment(%{status: status, paid_at: nil})], active_account())
        assert html =~ label
      end
    end

    test "shows the refund button for a refundable payment when the account is active" do
      doc = Floki.parse_document!(render_table([payment(%{})], active_account()))

      assert [_button] = Floki.find(doc, "button[phx-click=open_refund_modal]")
    end

    test "hides the refund button for a non-refundable payment" do
      html = render_table([payment(%{status: "pending", paid_at: nil})], active_account())
      doc = Floki.parse_document!(html)

      assert [] = Floki.find(doc, "button[phx-click=open_refund_modal]")
    end

    test "hides the refund button when the connect account is soft-deleted" do
      doc = Floki.parse_document!(render_table([payment(%{})], deleted_account()))

      assert [] = Floki.find(doc, "button[phx-click=open_refund_modal]")
    end
  end
end

defmodule TymeslotWeb.Dashboard.PaymentsSettings.CurrencySelectorTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Dashboard.PaymentsSettings.CurrencySelector

  defp render_selector(default_currency) do
    render_component(&CurrencySelector.currency_selector/1,
      account: %{default_currency: default_currency},
      myself: nil
    )
  end

  describe "currency_selector/1" do
    test "renders one tag per allowlisted currency" do
      doc = Floki.parse_document!(render_selector("eur"))

      buttons = Floki.find(doc, "button[phx-click=change_currency]")
      assert length(buttons) == length(MeetingPayments.currency_allowlist())
    end

    test "marks the account's default currency as the active tag" do
      doc = Floki.parse_document!(render_selector("eur"))

      active = Floki.find(doc, "button.btn-tag-selector-primary--active")
      assert [eur_button] = active
      assert Floki.attribute(eur_button, "phx-value-currency") == ["eur"]
    end

    test "shows symbol labels for known currencies and a bare code for CHF" do
      html = render_selector("usd")

      assert html =~ "$ USD"
      assert html =~ "€ EUR"
      assert html =~ "£ GBP"
      # CHF's symbol falls back to its code, so the label is the bare code,
      # never the duplicated "CHF CHF".
      assert html =~ "CHF"
      refute html =~ "CHF CHF"
    end
  end
end

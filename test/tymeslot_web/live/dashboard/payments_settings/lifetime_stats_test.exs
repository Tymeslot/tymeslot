defmodule TymeslotWeb.Dashboard.PaymentsSettings.LifetimeStatsTest do
  @moduledoc """
  The lifetime totals cards: one line per currency, never one sum labelled
  with whatever the default currency happens to be today.
  """

  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.PaymentsSettings.LifetimeStats

  defp render_stats(stats, currency \\ "chf") do
    render_component(&LifetimeStats.lifetime_stats/1,
      stats: stats,
      account: build(:connect_account, default_currency: currency)
    )
  end

  test "shows each currency's total on its own line" do
    html =
      render_stats([
        %{currency: "chf", received: 5_000, refunded: 0, platform_fee: 25},
        %{currency: "eur", received: 10_000, refunded: 500, platform_fee: 50}
      ])

    assert html =~ "CHF 50.00"
    assert html =~ "€100.00"
    assert html =~ "€5.00"
    refute html =~ "CHF 150.00"
  end

  test "shows zero in the default currency before any payment" do
    html = render_stats([])

    assert html =~ "CHF 0.00"
  end

  test "shows zero in an account currency outside the allowlist too" do
    assert render_stats([], "ron") =~ "RON 0.00"
  end

  test "shows zero in the fallback currency when the account has none" do
    assert render_stats([], nil) =~ "€0.00"
    assert render_stats([], "") =~ "€0.00"
  end
end

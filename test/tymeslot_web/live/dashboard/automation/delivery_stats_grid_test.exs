defmodule TymeslotWeb.Dashboard.Automation.DeliveryStatsGridTest do
  use ExUnit.Case, async: true

  @moduletag :components
  @moduletag :automation
  @moduletag :i18n

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.Automation.DeliveryComponents

  defp success_line(rate) do
    stats = %{
      total: 100,
      successful: rate,
      failed: 100 - rate,
      success_rate: rate,
      period_days: 7
    }

    render_component(&DeliveryComponents.delivery_stats_grid/1, stats: stats)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".text-green-600.font-medium")
    |> LazyHTML.text()
    |> String.trim()
  end

  test "names the success rate in English" do
    assert success_line(92) == "92% success rate"
  end

  # Italian elides the article before a number read with a vowel (8, 11, 80),
  # so the sentence carries no article before the rate at all.
  test "in Italian, puts no article before a rate read with a vowel" do
    Gettext.put_locale(TymeslotWeb.Gettext, "it")

    for rate <- [8, 11, 80] do
      assert success_line(rate) == "Tasso di successo: #{rate}%"
    end
  end
end

defmodule TymeslotWeb.Themes.Shared.SeriesPartsTest do
  @moduledoc """
  The total a paid series shows above the submit on the booking pages, in
  the page's language.
  """

  use ExUnit.Case, async: true

  @moduletag :scheduling

  alias TymeslotWeb.Themes.Shared.SeriesParts

  @paid %{payment_required: true, price_cents: 30_862}

  test "a paid series' total is written the way the page's language does" do
    assert SeriesParts.total_label(@paid, "eur", "en", 4) == "€1,234.48"
    assert SeriesParts.total_label(@paid, "eur", "de", 4) == "1.234,48 €"
  end

  test "a free type has no total" do
    assert SeriesParts.total_label(%{payment_required: false}, "eur", "en", 4) == nil
  end
end
